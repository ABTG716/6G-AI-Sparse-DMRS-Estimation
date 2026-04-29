#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║     Alt.1 Self-Supervised MLP-Mixer — DMRS Channel Denoising               ║
║     Based on Samsung R1-2500xxx, 3GPP RAN1 #119bis, Prague Oct 2025        ║
╚══════════════════════════════════════════════════════════════════════════════╝

Pipeline (matches Figure 25 from the proposal):
  r, p  ──► LS estimation  ──► [THIS MODEL: SSL MLP-Mixer @ DMRS]
         ──► Freq interpolation (incl. TOE) ──► Time interpolation (incl. FOE)
         ──► h_est

Architecture:  MLP-Mixer with 2-D continuous positional encoding
               + SNR conditioning (FiLM-style scale/shift)
               (Model backbone per Samsung proposal table: MLP-Mixer)

Self-Supervised Learning (label-free, Alt.1 principle):
  ┌─ Random-mask M% of DMRS tokens (replace with learned [MASK] token)
  ├─ Token-mixing MLPs aggregate info across adjacent DMRS REs
  │   (exploits channel smoothness in freq/time without ideal labels)
  └─ Combined loss:
       • Primary: MSE at masked positions vs. noisy LS
       • Regulariser: MSE at ALL positions (full reconstruction)
       → prevents divergence on unmasked tokens

Fixes applied (v2):
  • Higher mask ratio (50%) to force global channel learning
  • Combined loss (SSL + full-recon regulariser)
  • Checkpoint on va_full (full reconstruction) — not va_ssl
  • EMA (Exponential Moving Average) of model weights
  • Early stopping with patience
  • Increased model capacity (d_model=48, 3 layers)

Dataset (HDF5, expected in same directory as this script):
  /input_ls_real   [612,14,2,N]   LS estimate at DMRS (zero elsewhere)
  /input_ls_imag   [612,14,2,N]
  /dmrs_mask       [612,14]       binary, DMRS=1
  /snr_db          [N]            per-sample SNR in dB
  /rms_norm        [N]            per-sample RMS normalisation factor
  /alt1_ideal_real [408,2,N]      ideal H at DMRS (offline eval only)
  /alt1_ideal_imag [408,2,N]
  /alt1_pract_real [408,2,N]      MMSE@30 dB at DMRS (practical eval)
  /alt1_pract_imag [408,2,N]
"""

from __future__ import annotations
import os, sys, math, time, logging, copy
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional, Tuple, Dict

import h5py
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
from torch.optim import AdamW
from torch.optim.lr_scheduler import OneCycleLR

# ══════════════════════════════════════════════════════════════════════════════
# 1.  Configuration
# ══════════════════════════════════════════════════════════════════════════════
_SCRIPT_DIR = Path(__file__).resolve().parent

@dataclass
class Config:
    # ── paths (dataset in the same folder as this script) ──────────────────
    h5_path:   str = str(_SCRIPT_DIR / "dataset_sparse_fd.h5")
    ckpt_dir:  str = str(_SCRIPT_DIR / "checkpoints" / "alt1")
    log_dir:   str = str(_SCRIPT_DIR / "logs" / "alt1")

    # ── NR grid ────────────────────────────────────────────────────────────
    n_sc:    int = 612    # subcarriers in resource grid
    n_sym:   int = 14     # OFDM symbols per slot
    n_ports: int = 2      # Rx antenna ports
    n_dmrs:  int = 408    # DMRS REs (from dmrs_mask)

    # ── MLP-Mixer model ──────────────────────────────────────────────────
    d_model:         int   = 48     # hidden dimension  (was 32)
    n_layers:        int   = 3      # number of Mixer blocks  (was 2)
    token_mix_dim:   int   = 96     # hidden dim for token-mixing MLP  (was 64)
    channel_mix_dim: int   = 96     # hidden dim for channel-mixing MLP  (was 64)
    dropout:         float = 0.10   # regularisation  (was 0.05)
    drop_path:       float = 0.10   # stochastic depth max rate  (was 0.05)
    snr_cond:        bool  = True   # FiLM SNR conditioning

    # ── self-supervised masking ────────────────────────────────────────────
    mask_ratio: float = 0.50        # fraction of DMRS positions masked  (was 0.25)

    # ── combined loss ──────────────────────────────────────────────────────
    recon_weight: float = 0.5       # weight for full-reconstruction regulariser

    # ── EMA ────────────────────────────────────────────────────────────────
    ema_decay: float = 0.998        # EMA decay factor for model weights

    # ── training ───────────────────────────────────────────────────────────
    batch_size:   int   = 64
    lr:           float = 3e-4
    weight_decay: float = 1e-4
    epochs:       int   = 120       # more epochs  (was 80)
    warmup_pct:   float = 0.08      # fraction of steps for LR warm-up  (was 0.06)
    grad_clip:    float = 1.0
    seed:         int   = 42
    patience:     int   = 20        # early stopping patience  (NEW)

    # ── data split ─────────────────────────────────────────────────────────
    train_frac: float = 0.80
    val_frac:   float = 0.10        # test = remaining 10%

    # ── system ─────────────────────────────────────────────────────────────
    num_workers: int  = 4
    pin_memory:  bool = True
    amp:         bool = True        # automatic mixed precision (CUDA only)
    device:      str  = "cuda" if torch.cuda.is_available() else "cpu"


# ══════════════════════════════════════════════════════════════════════════════
# 2.  Dataset
# ══════════════════════════════════════════════════════════════════════════════
class Alt1Dataset(Dataset):
    """
    Yields per sample:
      x      : float32 [N_dmrs, 4]   LS at DMRS  (re_p0, im_p0, re_p1, im_p1)
      pos    : float32 [N_dmrs, 2]   (sc_norm, sym_norm) ∈ [0, 1]²
      snr_db : float32 scalar
    HDF5 is opened lazily (once per worker) to be multiprocessing-safe.
    """

    def __init__(self, h5_path: str, indices: np.ndarray, cfg: Config):
        self.h5_path = h5_path
        self.indices = indices.copy()
        self.cfg     = cfg
        self._file   = None

        # ── DMRS positions (fixed for entire dataset) ──────────────────────
        with h5py.File(h5_path, "r") as f:
            dmrs_mask = f["dmrs_mask"][:]               # [14, 612]
            self._snr = f["snr_db"][:].squeeze().astype(np.float32)  # [N]

        sym_idx, sc_idx = np.where(dmrs_mask)            # mask is [sym, sc]
        order = np.lexsort((sc_idx, sym_idx))            # symbol-major sort
        self._sc  = sc_idx[order].astype(np.int32)       # [N_dmrs]
        self._sym = sym_idx[order].astype(np.int32)      # [N_dmrs]
        assert len(self._sc) == cfg.n_dmrs, \
            f"Expected {cfg.n_dmrs} DMRS but mask gives {len(self._sc)}"

        # normalised position tensor (shared, no grad)
        self.pos_fixed = torch.from_numpy(np.stack([
            self._sc  / (cfg.n_sc  - 1),
            self._sym / (cfg.n_sym - 1),
        ], axis=-1).astype(np.float32))                  # [N_dmrs, 2]

        self._snr_local = self._snr[indices]

    # ── lazy HDF5 opener ───────────────────────────────────────────────────
    def _open(self):
        if self._file is None:
            self._file = h5py.File(self.h5_path, "r", swmr=True)

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, idx: int):
        self._open()
        s = int(self.indices[idx])

        ls_re = self._file["input_ls_real"][s]           # [2, 14, 612]
        ls_im = self._file["input_ls_imag"][s]

        # extract DMRS positions ───────────────────────────────────────────
        re = ls_re[:, self._sym, self._sc].T             # [N_dmrs, 2]
        im = ls_im[:, self._sym, self._sc].T

        # interleave to [N_dmrs, 4]: re_p0, im_p0, re_p1, im_p1
        x = np.stack([re[:, 0], im[:, 0],
                      re[:, 1], im[:, 1]], axis=-1).astype(np.float32)

        return {
            "x":      torch.from_numpy(x),
            "pos":    self.pos_fixed.clone(),
            "snr_db": torch.tensor(self._snr_local[idx], dtype=torch.float32),
        }


def build_loaders(cfg: Config) -> Tuple[DataLoader, DataLoader, DataLoader, Dict]:
    with h5py.File(cfg.h5_path, "r") as f:
        N = int(f["snr_db"].shape[0])

    rng  = np.random.default_rng(cfg.seed)
    perm = rng.permutation(N)
    n_tr = int(N * cfg.train_frac)
    n_va = int(N * cfg.val_frac)

    splits = {
        "train": perm[:n_tr],
        "val":   perm[n_tr : n_tr + n_va],
        "test":  perm[n_tr + n_va :],
    }

    kw = dict(batch_size=cfg.batch_size, num_workers=cfg.num_workers,
              pin_memory=cfg.pin_memory,
              persistent_workers=(cfg.num_workers > 0))
    loaders = {
        split: DataLoader(
            Alt1Dataset(cfg.h5_path, idx, cfg),
            shuffle=(split == "train"), **kw
        )
        for split, idx in splits.items()
    }
    return loaders["train"], loaders["val"], loaders["test"], splits


# ══════════════════════════════════════════════════════════════════════════════
# 3.  Building Blocks
# ══════════════════════════════════════════════════════════════════════════════

# ── 3a.  2-D Continuous Positional Encoding ───────────────────────────────────
class Pos2DEncoding(nn.Module):
    """
    Maps continuous (sc_norm, sym_norm) ∈ [0,1]² → R^{d_model}.
    Uses learnable log-spaced frequency banks — handles arbitrary DMRS
    positions without assuming a regular grid.
    """
    def __init__(self, d_model: int):
        super().__init__()
        assert d_model % 4 == 0
        half = d_model // 4
        self.freq_sc  = nn.Parameter(
            torch.exp(torch.linspace(0, math.log(512), half)))
        self.freq_sym = nn.Parameter(
            torch.exp(torch.linspace(0, math.log(512), half)))

    def forward(self, pos: torch.Tensor) -> torch.Tensor:
        """pos: [B, N, 2]  →  [B, N, d_model]"""
        sc  = pos[..., 0:1]                                      # [B, N, 1]
        sym = pos[..., 1:2]
        a_sc  = sc  * self.freq_sc.view(1, 1, -1)               # [B, N, h]
        a_sym = sym * self.freq_sym.view(1, 1, -1)
        return torch.cat([torch.sin(a_sc),  torch.cos(a_sc),
                          torch.sin(a_sym), torch.cos(a_sym)], dim=-1)


# ── 3b.  SNR Conditioning (FiLM) ─────────────────────────────────────────────
class SNRConditioner(nn.Module):
    """
    Embeds scalar SNR (dB) → (γ, β) for FiLM scale/shift on every token.
    Conditions the denoising strength without modifying the mixing patterns.
    """
    def __init__(self, d_model: int, n_freqs: int = 32):
        super().__init__()
        self.register_buffer(
            "freqs", torch.exp(torch.linspace(0, math.log(100), n_freqs)))
        self.mlp = nn.Sequential(
            nn.Linear(2 * n_freqs, d_model),
            nn.SiLU(),
            nn.Linear(d_model, 2 * d_model),          # → (γ, β)
        )

    def forward(self, snr_db: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        """snr_db: [B]  →  γ, β each [B, 1, d_model]"""
        s   = snr_db.view(-1, 1) * self.freqs.view(1, -1)       # [B, F]
        emb = torch.cat([torch.sin(s), torch.cos(s)], dim=-1)   # [B, 2F]
        out = self.mlp(emb).unsqueeze(1)                          # [B, 1, 2d]
        gamma, beta = out.chunk(2, dim=-1)                        # each [B, 1, d]
        return gamma, beta


# ── 3c.  Drop Path (Stochastic Depth) ────────────────────────────────────────
class DropPath(nn.Module):
    """Per-sample stochastic depth for regularisation."""
    def __init__(self, drop_prob: float = 0.0):
        super().__init__()
        self.drop_prob = drop_prob

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if not self.training or self.drop_prob == 0.0:
            return x
        keep  = 1.0 - self.drop_prob
        shape = (x.shape[0],) + (1,) * (x.ndim - 1)
        mask  = torch.bernoulli(
            torch.full(shape, keep, device=x.device, dtype=x.dtype))
        return x * mask / keep


# ── 3d.  MLP-Mixer Block ─────────────────────────────────────────────────────
class MixerBlock(nn.Module):
    """
    Single MLP-Mixer block (per Samsung Alt.1 backbone):
      1. Token-mixing:   shares info across DMRS positions (spatial)
      2. FiLM:           SNR-adaptive scale/shift
      3. Channel-mixing: per-position feature transform
    """
    def __init__(self, n_tokens: int, d_model: int,
                 token_mix_dim: int, channel_mix_dim: int,
                 dropout: float, drop_path: float, snr_cond: bool):
        super().__init__()
        self.snr_cond_flag = snr_cond

        # ─ token mixing (spatial) ──────────────────────────────────────────
        self.norm1 = nn.LayerNorm(d_model)
        self.token_mix = nn.Sequential(
            nn.Linear(n_tokens, token_mix_dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(token_mix_dim, n_tokens),
            nn.Dropout(dropout),
        )

        # ─ channel mixing (per-position features) ─────────────────────────
        self.norm2 = nn.LayerNorm(d_model)
        self.channel_mix = nn.Sequential(
            nn.Linear(d_model, channel_mix_dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(channel_mix_dim, d_model),
            nn.Dropout(dropout),
        )

        self.drop_path = DropPath(drop_path) if drop_path > 0. else nn.Identity()

    def forward(self, x: torch.Tensor,
                gamma: Optional[torch.Tensor] = None,
                beta:  Optional[torch.Tensor] = None) -> torch.Tensor:
        """x: [B, N, d]  →  [B, N, d]"""
        # ── token mixing: transpose → MLP over N dim → transpose back ─────
        h = self.norm1(x)                                         # [B, N, d]
        h = h.transpose(1, 2)                                    # [B, d, N]
        h = self.token_mix(h)                                     # [B, d, N]
        h = h.transpose(1, 2)                                    # [B, N, d]
        x = x + self.drop_path(h)

        # ── FiLM conditioning (after token mixing) ────────────────────────
        if self.snr_cond_flag and gamma is not None:
            x = x * (1 + gamma) + beta

        # ── channel mixing ────────────────────────────────────────────────
        h = self.norm2(x)                                         # [B, N, d]
        h = self.channel_mix(h)                                   # [B, N, d]
        x = x + self.drop_path(h)

        return x


# ══════════════════════════════════════════════════════════════════════════════
# 4.  Alt.1 MLP-Mixer Model
# ══════════════════════════════════════════════════════════════════════════════
class Alt1Mixer(nn.Module):
    """
    Self-supervised denoising MLP-Mixer operating on DMRS REs only.

    Forward (training):
      x    [B, N_dmrs, 4]   noisy LS estimates (re_p0, im_p0, re_p1, im_p1)
      pos  [B, N_dmrs, 2]   normalised (sc, sym) coords ∈ [0, 1]²
      snr  [B]              SNR in dB (optional conditioning)
      mask [B, N_dmrs] bool True = position is masked

    Returns:
      out  [B, N_dmrs, 4]   reconstructed / denoised channel at ALL positions

    Loss is computed only on masked tokens (SSL — no ideal H needed).
    Inference: call without mask → denoises all DMRS tokens.
    """

    def __init__(self, cfg: Config):
        super().__init__()
        self.cfg = cfg
        d = cfg.d_model

        # input projection: 4 floats per RE → d_model
        self.input_proj = nn.Sequential(
            nn.Linear(4, d),
            nn.LayerNorm(d),
        )

        # learnable [MASK] token
        self.mask_token = nn.Parameter(torch.randn(1, 1, d) * 0.02)

        # 2-D continuous positional encoding
        self.pos_enc = Pos2DEncoding(d)

        # SNR conditioner
        self.snr_cond = SNRConditioner(d) if cfg.snr_cond else None

        # MLP-Mixer blocks with linearly increasing drop-path rate
        dp_rates = torch.linspace(0, cfg.drop_path, cfg.n_layers).tolist()
        self.blocks = nn.ModuleList([
            MixerBlock(
                n_tokens=cfg.n_dmrs,
                d_model=d,
                token_mix_dim=cfg.token_mix_dim,
                channel_mix_dim=cfg.channel_mix_dim,
                dropout=cfg.dropout,
                drop_path=dp_rates[i],
                snr_cond=cfg.snr_cond,
            )
            for i in range(cfg.n_layers)
        ])
        self.norm_out = nn.LayerNorm(d)

        # output head: d_model → 4  (re_p0, im_p0, re_p1, im_p1)
        self.head = nn.Linear(d, 4)

        self._init_weights()

    def _init_weights(self):
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.trunc_normal_(m.weight, std=0.02)
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    # ── forward ───────────────────────────────────────────────────────────
    def forward(self,
                x:    torch.Tensor,
                pos:  torch.Tensor,
                snr:  Optional[torch.Tensor] = None,
                mask: Optional[torch.Tensor] = None,
                ) -> torch.Tensor:
        """
        x    : [B, N, 4]
        pos  : [B, N, 2]
        snr  : [B]  (dB)
        mask : [B, N] bool — True → replace with mask token
        →      [B, N, 4]
        """
        # 1. project
        tok = self.input_proj(x)                                   # [B, N, d]

        # 2. replace masked positions with [MASK] token
        if mask is not None:
            m = mask.unsqueeze(-1).float()                         # [B, N, 1]
            tok = tok * (1 - m) + self.mask_token * m

        # 3. add 2-D positional encoding
        tok = tok + self.pos_enc(pos)                              # [B, N, d]

        # 4. SNR conditioning
        gamma, beta = None, None
        if self.snr_cond is not None and snr is not None:
            gamma, beta = self.snr_cond(snr)                      # [B, 1, d]

        # 5. MLP-Mixer blocks
        for blk in self.blocks:
            tok = blk(tok, gamma, beta)

        tok = self.norm_out(tok)                                   # [B, N, d]

        # 6. output
        return self.head(tok)                                      # [B, N, 4]

    # ── convenience ───────────────────────────────────────────────────────
    @torch.no_grad()
    def denoise(self, x: torch.Tensor, pos: torch.Tensor,
                snr: Optional[torch.Tensor] = None) -> torch.Tensor:
        """Full denoising at inference — no masking."""
        self.eval()
        return self.forward(x, pos, snr, mask=None)


# ══════════════════════════════════════════════════════════════════════════════
# 4b.  EMA (Exponential Moving Average) of model weights
# ══════════════════════════════════════════════════════════════════════════════
class ModelEMA:
    """
    Maintains an exponential moving average of model parameters.
    The EMA model is used for validation and final evaluation — produces
    smoother, more generalised weights than any single training snapshot.
    """
    def __init__(self, model: nn.Module, decay: float = 0.998):
        self.decay = decay
        self.ema_model = copy.deepcopy(model)
        self.ema_model.eval()
        for p in self.ema_model.parameters():
            p.requires_grad_(False)

    @torch.no_grad()
    def update(self, model: nn.Module):
        for ema_p, model_p in zip(self.ema_model.parameters(),
                                   model.parameters()):
            ema_p.data.mul_(self.decay).add_(model_p.data, alpha=1 - self.decay)

    def state_dict(self):
        return self.ema_model.state_dict()

    def load_state_dict(self, sd):
        self.ema_model.load_state_dict(sd)


# ══════════════════════════════════════════════════════════════════════════════
# 5.  Self-Supervised Masking + Loss
# ══════════════════════════════════════════════════════════════════════════════
def random_mask(B: int, N: int, ratio: float,
                device: torch.device) -> torch.Tensor:
    """
    Vectorised mask: exactly round(N*ratio) positions masked per sample.
    Guarantees ≥ 1 context token and ≥ 1 target token.
    Returns [B, N] bool, True = masked.
    """
    n_mask = max(1, min(N - 1, round(N * ratio)))
    noise  = torch.rand(B, N, device=device)
    # argsort gives random permutation; take first n_mask as masked
    ids_sorted = torch.argsort(noise, dim=1)
    mask = torch.zeros(B, N, dtype=torch.bool, device=device)
    mask.scatter_(1, ids_sorted[:, :n_mask], True)
    return mask


def combined_loss(pred: torch.Tensor,
                  target: torch.Tensor,
                  mask: torch.Tensor,
                  recon_weight: float = 0.5) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """
    Combined SSL + full-reconstruction loss.

    * ssl_loss  : MSE on masked tokens only  (primary self-supervised signal)
    * recon_loss: MSE on ALL tokens  (regulariser — prevents unmasked divergence)
    * total     : ssl_loss + recon_weight × recon_loss

    pred   : [B, N, 4]
    target : [B, N, 4]
    mask   : [B, N] bool

    Returns (total_loss, ssl_loss, recon_loss) — all scalars.
    """
    mse_per_token = ((pred - target) ** 2).mean(-1)               # [B, N]

    ssl_loss  = mse_per_token[mask].mean()
    recon_loss = mse_per_token.mean()

    total = ssl_loss + recon_weight * recon_loss
    return total, ssl_loss, recon_loss


# ══════════════════════════════════════════════════════════════════════════════
# 6.  Training / Validation Loop
# ══════════════════════════════════════════════════════════════════════════════
def run_epoch(model, loader, cfg, device,
              optimizer=None, scheduler=None, scaler=None, ema=None):
    training = optimizer is not None
    model.train(training)

    use_amp = cfg.amp and device.type == "cuda"
    total_ssl, total_recon, total_full, n = 0.0, 0.0, 0.0, 0

    for batch in loader:
        x   = batch["x"].to(device, non_blocking=True)            # [B, N, 4]
        pos = batch["pos"].to(device, non_blocking=True)          # [B, N, 2]
        snr = batch["snr_db"].to(device, non_blocking=True)       # [B]
        B, N, _ = x.shape

        mask = random_mask(B, N, cfg.mask_ratio, device)

        # ── forward ───────────────────────────────────────────────────────
        with torch.amp.autocast("cuda", enabled=use_amp):
            pred = model(x, pos, snr, mask)
            loss, ssl_l, recon_l = combined_loss(pred, x, mask, cfg.recon_weight)

        # ── backward (training only) ─────────────────────────────────────
        if training:
            optimizer.zero_grad(set_to_none=True)
            if scaler is not None:
                scaler.scale(loss).backward()
                scaler.unscale_(optimizer)
                nn.utils.clip_grad_norm_(model.parameters(), cfg.grad_clip)
                scaler.step(optimizer)
                scaler.update()
            else:
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), cfg.grad_clip)
                optimizer.step()
            scheduler.step()

            # ── EMA update ────────────────────────────────────────────────
            if ema is not None:
                ema.update(model)

        # ── validation: also measure full (unmasked) reconstruction ──────
        if not training:
            with torch.no_grad(), torch.amp.autocast("cuda", enabled=use_amp):
                pred_full   = model(x, pos, snr, mask=None)
                total_full += F.mse_loss(pred_full, x).item()

        total_ssl   += ssl_l.item()
        total_recon += recon_l.item()
        n += 1

    metrics = {
        "ssl":   total_ssl   / max(n, 1),
        "recon": total_recon / max(n, 1),
    }
    if not training:
        metrics["full"] = total_full / max(n, 1)
    return metrics


# ══════════════════════════════════════════════════════════════════════════════
# 7.  NMSE Evaluation (offline, uses ideal / practical H labels)
# ══════════════════════════════════════════════════════════════════════════════
@torch.no_grad()
def evaluate_nmse(model: Alt1Mixer, h5_path: str,
                  test_indices: np.ndarray, cfg: Config,
                  device: torch.device,
                  label: str = "alt1_ideal") -> float:
    """
    NMSE (dB) vs. specified reference at DMRS positions.
    label: 'alt1_ideal' (perfect H) or 'alt1_pract' (MMSE@30 dB).
    Only used for benchmarking — NOT used during SSL training.
    """
    model.eval()
    ds     = Alt1Dataset(h5_path, test_indices, cfg)
    loader = DataLoader(ds, batch_size=cfg.batch_size, shuffle=False,
                        num_workers=cfg.num_workers)

    use_amp = cfg.amp and device.type == "cuda"

    with h5py.File(h5_path, "r") as f:
        h_re_all = f[f"{label}_real"][:]                          # [N, 2, 408]
        h_im_all = f[f"{label}_imag"][:]

    num_acc, den_acc = 0.0, 0.0
    for i, batch in enumerate(loader):
        x   = batch["x"].to(device)
        pos = batch["pos"].to(device)
        snr = batch["snr_db"].to(device)

        with torch.amp.autocast("cuda", enabled=use_amp):
            pred = model.denoise(x, pos, snr)
        pred = pred.cpu().numpy()                                 # [B, N, 4]

        s0   = i * cfg.batch_size
        sidx = test_indices[s0 : s0 + len(x)]

        h_re = h_re_all[sidx].transpose(0, 2, 1)                 # [B, 408, 2]
        h_im = h_im_all[sidx].transpose(0, 2, 1)
        ref  = np.stack([h_re[..., 0], h_im[..., 0],
                         h_re[..., 1], h_im[..., 1]], axis=-1)   # [B, N, 4]

        num_acc += np.sum((pred - ref) ** 2)
        den_acc += np.sum(ref ** 2)

    nmse_lin = num_acc / (den_acc + 1e-12)
    return 10 * math.log10(nmse_lin + 1e-12)


# ══════════════════════════════════════════════════════════════════════════════
# 8.  Main Training Script
# ══════════════════════════════════════════════════════════════════════════════
def main():
    cfg    = Config()
    device = torch.device(cfg.device)

    torch.manual_seed(cfg.seed)
    np.random.seed(cfg.seed)

    Path(cfg.ckpt_dir).mkdir(parents=True, exist_ok=True)
    Path(cfg.log_dir).mkdir(parents=True,  exist_ok=True)

    # Force UTF-8 on Windows console to avoid cp1252 encoding errors
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%H:%M:%S",
        handlers=[
            logging.StreamHandler(sys.stdout),
            logging.FileHandler(f"{cfg.log_dir}/training.log", encoding="utf-8"),
        ],
    )
    log = logging.getLogger(__name__)
    log.info("═" * 66)
    log.info("  Alt.1 MLP-Mixer v2 — Self-Supervised DMRS Denoiser")
    log.info("═" * 66)
    log.info(f"  Device      : {device}  |  AMP: {cfg.amp and device.type=='cuda'}")
    log.info(f"  d_model     : {cfg.d_model}  |  layers: {cfg.n_layers}")
    log.info(f"  token_mix   : {cfg.token_mix_dim}  "
             f"|  channel_mix: {cfg.channel_mix_dim}")
    log.info(f"  Masking     : {cfg.mask_ratio*100:.0f}%  "
             f"|  SNR cond: {cfg.snr_cond}")
    log.info(f"  Drop path   : {cfg.drop_path}  |  Dropout: {cfg.dropout}")
    log.info(f"  Recon wt    : {cfg.recon_weight}  |  EMA decay: {cfg.ema_decay}")
    log.info(f"  Patience    : {cfg.patience} epochs")

    # ── data ──────────────────────────────────────────────────────────────
    log.info("Loading dataset …")
    train_dl, val_dl, test_dl, splits = build_loaders(cfg)
    log.info(f"  Train: {len(train_dl.dataset):>7,}  "
             f"Val: {len(val_dl.dataset):>6,}  "
             f"Test: {len(test_dl.dataset):>6,}")

    # ── model ─────────────────────────────────────────────────────────────
    model  = Alt1Mixer(cfg).to(device)
    n_par  = sum(p.numel() for p in model.parameters() if p.requires_grad)
    log.info(f"  Parameters  : {n_par:,}")

    # ── EMA ───────────────────────────────────────────────────────────────
    ema = ModelEMA(model, decay=cfg.ema_decay)

    # ── optimiser / scheduler ─────────────────────────────────────────────
    opt   = AdamW(model.parameters(), lr=cfg.lr,
                  weight_decay=cfg.weight_decay, betas=(0.9, 0.95))
    total_steps = cfg.epochs * len(train_dl)
    sched = OneCycleLR(opt, max_lr=cfg.lr, total_steps=total_steps,
                       pct_start=cfg.warmup_pct, anneal_strategy="cos")
    scaler = torch.amp.GradScaler("cuda") \
             if (cfg.amp and device.type == "cuda") else None

    # ── training loop ─────────────────────────────────────────────────────
    best_val_full = float("inf")
    patience_counter = 0
    history = []
    log.info("─" * 66)

    for epoch in range(1, cfg.epochs + 1):
        t0 = time.perf_counter()

        tr = run_epoch(model, train_dl, cfg, device, opt, sched, scaler, ema)

        # ── validate with EMA model ───────────────────────────────────────
        va = run_epoch(ema.ema_model, val_dl, cfg, device)

        dt  = time.perf_counter() - t0
        row = dict(epoch=epoch, **{f"tr_{k}": v for k, v in tr.items()},
                                **{f"va_{k}": v for k, v in va.items()},
                                secs=dt)
        history.append(row)

        log.info(
            f"Epoch {epoch:03d}/{cfg.epochs}  "
            f"tr_ssl={tr['ssl']:.4f}  tr_recon={tr['recon']:.4f}  "
            f"va_ssl={va['ssl']:.4f}  va_full={va['full']:.4f}  "
            f"({dt:.0f}s)"
        )

        # ── checkpoint on va_full (full reconstruction quality) ───────────
        if va["full"] < best_val_full:
            best_val_full = va["full"]
            patience_counter = 0
            torch.save(
                {"epoch": epoch,
                 "state": ema.ema_model.state_dict(),
                 "model_state": model.state_dict(),
                 "opt":   opt.state_dict(),
                 "val_full": best_val_full,
                 "cfg":   cfg},
                f"{cfg.ckpt_dir}/best.pt",
            )
            log.info(f"  ↳ ✓ Best checkpoint saved  (va_full={best_val_full:.4f})")
        else:
            patience_counter += 1
            if patience_counter >= cfg.patience:
                log.info(f"  ↳ Early stopping triggered (patience={cfg.patience})")
                break

    torch.save(ema.ema_model.state_dict(), f"{cfg.ckpt_dir}/final.pt")
    np.save(f"{cfg.log_dir}/history.npy", history)
    log.info("Training complete.")

    # ── offline NMSE benchmarks (using EMA best checkpoint) ───────────────
    log.info("Running NMSE evaluation on test set …")
    ckpt = torch.load(f"{cfg.ckpt_dir}/best.pt", map_location=device,
                      weights_only=False)
    eval_model = Alt1Mixer(cfg).to(device)
    eval_model.load_state_dict(ckpt["state"])

    nmse_ideal = evaluate_nmse(eval_model, cfg.h5_path, splits["test"],
                               cfg, device, label="alt1_ideal")
    nmse_pract = evaluate_nmse(eval_model, cfg.h5_path, splits["test"],
                               cfg, device, label="alt1_pract")
    log.info(f"  Test NMSE vs ideal H : {nmse_ideal:.2f} dB")
    log.info(f"  Test NMSE vs pract H : {nmse_pract:.2f} dB")
    log.info("═" * 66)


# ══════════════════════════════════════════════════════════════════════════════
# 9.  Inference Helper (drop-in for legacy interpolation pipeline)
# ══════════════════════════════════════════════════════════════════════════════
class Alt1Denoiser:
    """
    Production wrapper — plug in place of 'AI denoise' block in Figure 25.

    Usage:
        denoiser = Alt1Denoiser("checkpoints/alt1/best.pt", cfg)
        h_dmrs   = denoiser(ls_re, ls_im, snr_db)   # [408, 2] complex64
        # → pass h_dmrs into legacy freq/time interpolation
    """

    def __init__(self, ckpt_path: str, cfg: Config, device: str = "cpu"):
        self.device = torch.device(device)
        self.cfg    = cfg
        self.model  = Alt1Mixer(cfg).to(self.device)
        ckpt = torch.load(ckpt_path, map_location=self.device,
                          weights_only=False)
        self.model.load_state_dict(ckpt["state"])
        self.model.eval()

        # precompute DMRS position tensor
        with h5py.File(cfg.h5_path, "r") as f:
            dmrs_mask = f["dmrs_mask"][:]                 # [14, 612]
        sym_idx, sc_idx = np.where(dmrs_mask)
        order = np.lexsort((sc_idx, sym_idx))
        self._sc  = sc_idx[order]
        self._sym = sym_idx[order]
        self._pos = torch.tensor(np.stack([
            self._sc  / (cfg.n_sc  - 1),
            self._sym / (cfg.n_sym - 1),
        ], axis=-1).astype(np.float32)).unsqueeze(0).to(self.device)

    @torch.no_grad()
    def __call__(self, ls_re: np.ndarray, ls_im: np.ndarray,
                 snr_db: float = 20.0) -> np.ndarray:
        """
        ls_re, ls_im : [612, 14, 2]  full-grid LS estimates
        snr_db       : scalar  (dB)
        returns      : [408, 2]  complex64 denoised channel at DMRS
        """
        re = ls_re[self._sc, self._sym, :]                        # [408, 2]
        im = ls_im[self._sc, self._sym, :]
        x  = np.stack([re[:, 0], im[:, 0],
                       re[:, 1], im[:, 1]], axis=-1).astype(np.float32)
        x   = torch.from_numpy(x).unsqueeze(0).to(self.device)   # [1, 408, 4]
        snr = torch.tensor([snr_db], dtype=torch.float32,
                           device=self.device)

        out = self.model.denoise(x, self._pos, snr)
        out = out.squeeze(0).cpu().numpy()                         # [408, 4]

        # reconstruct complex: port 0 → col 0 + j*col 1,  port 1 → col 2 + j*col 3
        h = np.stack([out[:, 0] + 1j * out[:, 1],
                      out[:, 2] + 1j * out[:, 3]], axis=-1)       # [408, 2]
        return h.astype(np.complex64)


# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    main()