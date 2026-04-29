#!/usr/bin/env python3
"""Count FLOPs for Alt1Mixer using dummy inputs (no dataset needed)."""

import torch
from alt1_transformer import Config, Alt1Mixer

cfg   = Config()
model = Alt1Mixer(cfg).eval()

# -- dummy inputs (same shapes the model expects) --------------------------
B = 1
x   = torch.randn(B, cfg.n_dmrs, 4)        # [1, 408, 4]
pos = torch.randn(B, cfg.n_dmrs, 2)         # [1, 408, 2]
snr = torch.tensor([15.0])                   # [1]

# -- Method 1: PyTorch built-in (requires PyTorch >= 2.1) ------------------
try:
    from torch.utils.flop_counter import FlopCounterMode
    with FlopCounterMode(model, display=False) as fcm:
        model(x, pos, snr, mask=None)
    total = fcm.get_total_flops()
    print(f"[PyTorch FlopCounter]  {total:>14,} FLOPs  ({total/1e6:.2f} M)")
except ImportError:
    print("[PyTorch FlopCounter]  not available (needs PyTorch >= 2.1)")

# -- Method 2: thop (pip install thop) -------------------------------------
try:
    from thop import profile, clever_format
    flops, params = profile(model, inputs=(x, pos, snr, None), verbose=False)
    f_str, p_str = clever_format([flops, params], "%.2f")
    print(f"[thop]                 {flops:>14,.0f} FLOPs  ({f_str})  |  Params: {p_str}")
except ImportError:
    print("[thop]                 not available (pip install thop)")

# -- Method 3: manual parameter count (always works) -----------------------
n_params    = sum(p.numel() for p in model.parameters())
n_trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
print(f"\nParameters:  {n_params:,}  total  |  {n_trainable:,}  trainable")
print(f"\nModel config:")
print(f"  d_model={cfg.d_model}  layers={cfg.n_layers}  "
      f"token_mix={cfg.token_mix_dim}  channel_mix={cfg.channel_mix_dim}")