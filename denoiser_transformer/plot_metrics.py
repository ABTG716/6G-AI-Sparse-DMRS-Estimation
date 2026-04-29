#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  Alt.1 MLP-Mixer v2 — Training Metrics & NMSE Visualisation               ║
║  Parses log.txt and generates publication-quality plots including          ║
║  NMSE vs Epoch, SSL loss, reconstruction loss, and summary card.           ║
╚══════════════════════════════════════════════════════════════════════════════╝
"""

import re
import os
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from matplotlib.patches import FancyBboxPatch
from pathlib import Path

# ══════════════════════════════════════════════════════════════════════════════
# 1.  Parse the training log
# ══════════════════════════════════════════════════════════════════════════════
def parse_log(log_path: str) -> dict:
    """Parse training log and extract all metrics."""
    with open(log_path, "r", encoding="utf-8") as f:
        content = f.read()

    # ── Per-epoch metrics ─────────────────────────────────────────────────
    epoch_pattern = re.compile(
        r"Epoch\s+(\d+)/(\d+)\s+"
        r"tr_ssl=([\d.]+)\s+"
        r"tr_recon=([\d.]+)\s+"
        r"va_ssl=([\d.]+)\s+"
        r"va_full=([\d.]+)\s+"
        r"\((\d+)s\)"
    )
    epochs, total_epochs = [], 0
    tr_ssl, tr_recon, va_ssl, va_full, epoch_time = [], [], [], [], []

    for m in epoch_pattern.finditer(content):
        epochs.append(int(m.group(1)))
        total_epochs = int(m.group(2))
        tr_ssl.append(float(m.group(3)))
        tr_recon.append(float(m.group(4)))
        va_ssl.append(float(m.group(5)))
        va_full.append(float(m.group(6)))
        epoch_time.append(int(m.group(7)))

    # ── Final NMSE ────────────────────────────────────────────────────────
    nmse_ideal = nmse_pract = None
    m_ideal = re.search(r"Test NMSE vs ideal H\s*:\s*([-\d.]+)\s*dB", content)
    m_pract = re.search(r"Test NMSE vs pract H\s*:\s*([-\d.]+)\s*dB", content)
    if m_ideal: nmse_ideal = float(m_ideal.group(1))
    if m_pract: nmse_pract = float(m_pract.group(1))

    # ── Model config ─────────────────────────────────────────────────────
    config = {}
    for key, pattern in {
        "d_model":      r"d_model\s*:\s*(\d+)",
        "layers":       r"layers:\s*(\d+)",
        "token_mix":    r"token_mix\s*:\s*(\d+)",
        "channel_mix":  r"channel_mix:\s*(\d+)",
        "masking":      r"Masking\s*:\s*(\d+)%",
        "parameters":   r"Parameters\s*:\s*([\d,]+)",
        "train_samples": r"Train:\s*([\d,]+)",
        "recon_wt":     r"Recon wt\s*:\s*([\d.]+)",
        "ema_decay":    r"EMA decay:\s*([\d.]+)",
    }.items():
        m = re.search(pattern, content)
        if m: config[key] = m.group(1)

    return {
        "epochs": np.array(epochs), "total_epochs": total_epochs,
        "tr_ssl": np.array(tr_ssl), "tr_recon": np.array(tr_recon),
        "va_ssl": np.array(va_ssl), "va_full": np.array(va_full),
        "epoch_time": np.array(epoch_time),
        "nmse_ideal": nmse_ideal, "nmse_pract": nmse_pract,
        "config": config,
    }


# ══════════════════════════════════════════════════════════════════════════════
# 2.  Create the plots
# ══════════════════════════════════════════════════════════════════════════════
def plot_all(data: dict, output_path: str = "training_metrics_plot.png"):
    """Generate 5-panel dashboard with NMSE vs Epoch as the centrepiece."""

    epochs   = data["epochs"]
    tr_ssl   = data["tr_ssl"]
    tr_recon = data["tr_recon"]
    va_ssl   = data["va_ssl"]
    va_full  = data["va_full"]

    best_idx   = int(np.argmin(va_full))
    best_epoch = int(epochs[best_idx])
    best_full  = va_full[best_idx]

    # NMSE proxy in dB  (10·log10 of full-recon MSE)
    va_nmse_db = 10 * np.log10(va_full + 1e-12)
    tr_nmse_db = 10 * np.log10(tr_recon + 1e-12)

    # ── Style ─────────────────────────────────────────────────────────────
    plt.style.use("dark_background")
    plt.rcParams.update({
        "font.family": "sans-serif", "font.size": 11,
        "axes.titlesize": 14, "axes.labelsize": 12,
    })

    # Layout: row 1 = NMSE large plot + summary card
    #         row 2 = SSL loss | Recon loss | Convergence speed
    fig = plt.figure(figsize=(22, 15))
    gs = gridspec.GridSpec(
        2, 3, height_ratios=[1.2, 1],
        hspace=0.30, wspace=0.28,
        left=0.05, right=0.97, top=0.91, bottom=0.05,
    )

    C_TR     = "#00ffcc"
    C_VA     = "#ff00ff"
    C_RECON  = "#ff9900"
    C_FULL   = "#ffff00"
    C_NMSE   = "#ff4444"
    C_NMSE_T = "#ff8888"
    C_BEST   = "#00ff00"
    C_IDEAL  = "#00ccff"
    C_PRACT  = "#ff66cc"
    C_VLINE  = "#ffffff"

    # ══════════════════════════════════════════════════════════════════════
    # Panel 1 (top-left, spans 2 cols):  ★ NMSE vs Epoch  ★
    # ══════════════════════════════════════════════════════════════════════
    ax_nmse = fig.add_subplot(gs[0, 0:2])

    ax_nmse.plot(epochs, va_nmse_db, label="Val NMSE (full recon, dB)",
                 color=C_NMSE, linewidth=2.5, marker="D", markersize=4,
                 markevery=5, zorder=3)
    ax_nmse.plot(epochs, tr_nmse_db, label="Train NMSE (recon, dB)",
                 color=C_NMSE_T, linewidth=1.5, linestyle="--",
                 marker="o", markersize=3, markevery=5, alpha=0.7, zorder=2)

    # Best epoch marker
    ax_nmse.scatter([best_epoch], [va_nmse_db[best_idx]], color=C_BEST,
                    s=150, zorder=5, edgecolors="white", linewidths=1.5,
                    label=f"Best epoch {best_epoch}: {va_nmse_db[best_idx]:.2f} dB")
    ax_nmse.axvline(x=best_epoch, color=C_VLINE, linestyle=":", alpha=0.3)

    # Final test NMSE horizontal reference lines
    if data["nmse_ideal"] is not None:
        ax_nmse.axhline(y=data["nmse_ideal"], color=C_IDEAL, linestyle="-.",
                        linewidth=2, alpha=0.8,
                        label=f"Test NMSE vs Ideal H = {data['nmse_ideal']:.2f} dB")
    if data["nmse_pract"] is not None:
        ax_nmse.axhline(y=data["nmse_pract"], color=C_PRACT, linestyle="-.",
                        linewidth=2, alpha=0.8,
                        label=f"Test NMSE vs Pract H = {data['nmse_pract']:.2f} dB")

    # 0 dB reference (model = raw LS, no improvement)
    ax_nmse.axhline(y=0, color="#666666", linestyle="--", linewidth=1,
                    alpha=0.5, label="0 dB (no improvement)")

    ax_nmse.fill_between(epochs, va_nmse_db, 0, where=(va_nmse_db < 0),
                         color=C_BEST, alpha=0.05, interpolate=True)

    ax_nmse.set_title("★  NMSE vs Epoch  ★", fontsize=16, fontweight="bold",
                      color="#00ffcc")
    ax_nmse.set_xlabel("Epoch")
    ax_nmse.set_ylabel("NMSE  [dB]")
    ax_nmse.set_xlim(epochs[0], epochs[-1])
    ax_nmse.grid(True, alpha=0.15)
    ax_nmse.legend(fontsize=10, loc="upper right",
                   framealpha=0.7, fancybox=True)

    # Annotation
    ax_nmse.annotate(
        f"↓ Lower = better denoising\n"
        f"   Final: {data['nmse_ideal']:.2f} dB",
        xy=(epochs[-1] * 0.02, va_nmse_db[0] - 2),
        fontsize=10, color="#aaaaaa", style="italic",
    )

    # ══════════════════════════════════════════════════════════════════════
    # Panel 2 (top-right):  Summary Card
    # ══════════════════════════════════════════════════════════════════════
    ax_card = fig.add_subplot(gs[0, 2])
    ax_card.set_xlim(0, 10)
    ax_card.set_ylim(0, 10)
    ax_card.axis("off")

    bg = FancyBboxPatch((0.2, 0.2), 9.6, 9.6,
                        boxstyle="round,pad=0.3",
                        facecolor="#1a1a2e", edgecolor="#00ffcc",
                        linewidth=2, alpha=0.9)
    ax_card.add_patch(bg)

    ax_card.text(5, 9.2, "Final Test Results",
                 ha="center", va="center", fontsize=17,
                 fontweight="bold", color="#00ffcc")
    ax_card.plot([1.2, 8.8], [8.5, 8.5], color="#00ffcc",
                 linewidth=1.5, alpha=0.5)

    y = 7.4
    if data["nmse_ideal"] is not None:
        c = "#00ff88" if data["nmse_ideal"] < 0 else "#ff4444"
        ax_card.text(1.5, y, "NMSE vs Ideal H :", fontsize=13, color="#cccccc",
                     va="center")
        ax_card.text(8.8, y, f"{data['nmse_ideal']:.2f} dB", fontsize=19,
                     fontweight="bold", color=c, va="center", ha="right")
        y -= 1.2

    if data["nmse_pract"] is not None:
        c = "#00ff88" if data["nmse_pract"] < 0 else "#ff4444"
        ax_card.text(1.5, y, "NMSE vs Pract H :", fontsize=13, color="#cccccc",
                     va="center")
        ax_card.text(8.8, y, f"{data['nmse_pract']:.2f} dB", fontsize=19,
                     fontweight="bold", color=c, va="center", ha="right")
        y -= 1.2

    if data["nmse_ideal"] is not None and data["nmse_ideal"] < 0:
        imp = abs(data["nmse_ideal"])
        ax_card.text(5, y - 0.2,
                     f"✓  {imp:.1f} dB noise reduction",
                     ha="center", va="center", fontsize=13, color="#00ff88",
                     fontweight="bold",
                     bbox=dict(boxstyle="round,pad=0.4",
                               facecolor="#003322", edgecolor="#00ff88",
                               alpha=0.8))
        y -= 1.6

    ax_card.plot([1.2, 8.8], [y + 0.2, y + 0.2], color="#555555",
                 linewidth=1, alpha=0.6)
    cfg = data["config"]
    info = [
        f"d_model={cfg.get('d_model','?')}  layers={cfg.get('layers','?')}",
        f"mix={cfg.get('token_mix','?')}/{cfg.get('channel_mix','?')}  "
        f"mask={cfg.get('masking','?')}%",
        f"params={cfg.get('parameters','?')}",
        f"recon_wt={cfg.get('recon_wt','?')}  "
        f"EMA={cfg.get('ema_decay','?')}",
        f"best epoch={best_epoch}/{data['total_epochs']}",
    ]
    for i, line in enumerate(info):
        ax_card.text(5, y - 0.4 - i * 0.7, line, ha="center", va="center",
                     fontsize=9.5, color="#888888", family="monospace")

    # ══════════════════════════════════════════════════════════════════════
    # Panel 3 (bottom-left):  SSL Masked Loss
    # ══════════════════════════════════════════════════════════════════════
    ax_ssl = fig.add_subplot(gs[1, 0])
    ax_ssl.plot(epochs, tr_ssl, label="Train SSL", color=C_TR,
                linewidth=2, marker="o", markersize=3, markevery=5)
    ax_ssl.plot(epochs, va_ssl, label="Val SSL", color=C_VA,
                linewidth=2, marker="s", markersize=3, markevery=5)
    ax_ssl.axvline(x=best_epoch, color=C_VLINE, linestyle=":", alpha=0.3)
    ax_ssl.set_title("Self-Supervised Masked Loss (MSE)")
    ax_ssl.set_xlabel("Epoch")
    ax_ssl.set_ylabel("MSE Loss")
    ax_ssl.set_xlim(epochs[0], epochs[-1])
    ax_ssl.grid(True, alpha=0.15)
    ax_ssl.legend(fontsize=10)

    # ══════════════════════════════════════════════════════════════════════
    # Panel 4 (bottom-centre):  Reconstruction Loss
    # ══════════════════════════════════════════════════════════════════════
    ax_rec = fig.add_subplot(gs[1, 1])
    ax_rec.plot(epochs, tr_recon, label="Train Recon", color=C_RECON,
                linewidth=2, linestyle="--", marker="^", markersize=3,
                markevery=5)
    ax_rec.plot(epochs, va_full, label="Val Full Recon", color=C_FULL,
                linewidth=2, marker="D", markersize=3, markevery=5)
    ax_rec.axvline(x=best_epoch, color=C_VLINE, linestyle=":", alpha=0.3)
    ax_rec.scatter([best_epoch], [best_full], color=C_BEST, s=100, zorder=5,
                   edgecolors="white", linewidths=1,
                   label=f"Best = {best_full:.4f}")
    ax_rec.set_title("Full Reconstruction Loss (MSE)")
    ax_rec.set_xlabel("Epoch")
    ax_rec.set_ylabel("MSE Loss")
    ax_rec.set_xlim(epochs[0], epochs[-1])
    ax_rec.grid(True, alpha=0.15)
    ax_rec.legend(fontsize=10)

    # ══════════════════════════════════════════════════════════════════════
    # Panel 5 (bottom-right):  Training Speed / Convergence
    # ══════════════════════════════════════════════════════════════════════
    ax_time = fig.add_subplot(gs[1, 2])

    # Cumulative NMSE improvement per minute of training
    cum_time_min = np.cumsum(data["epoch_time"]) / 60.0
    ax_time.plot(cum_time_min, va_nmse_db, label="Val NMSE vs time",
                 color=C_NMSE, linewidth=2, marker="D", markersize=3,
                 markevery=5)
    if data["nmse_ideal"] is not None:
        ax_time.axhline(y=data["nmse_ideal"], color=C_IDEAL, linestyle="-.",
                        linewidth=1.5, alpha=0.6,
                        label=f"Final = {data['nmse_ideal']:.2f} dB")
    ax_time.axhline(y=0, color="#666666", linestyle="--", linewidth=1, alpha=0.4)
    ax_time.set_title("NMSE vs Training Time")
    ax_time.set_xlabel("Wall-clock time  [minutes]")
    ax_time.set_ylabel("NMSE  [dB]")
    ax_time.grid(True, alpha=0.15)
    ax_time.legend(fontsize=10)

    # ── Title ─────────────────────────────────────────────────────────────
    fig.suptitle(
        "Alt.1 MLP-Mixer v2 — Self-Supervised DMRS Channel Denoiser",
        fontsize=19, fontweight="bold", color="white", y=0.97,
    )

    plt.savefig(output_path, dpi=300, bbox_inches="tight",
                facecolor=fig.get_facecolor())
    print(f"✓ Plot saved to {os.path.abspath(output_path)}")
    plt.close(fig)


# ══════════════════════════════════════════════════════════════════════════════
# 3.  Main
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    script_dir = Path(__file__).resolve().parent
    candidates = [
        script_dir / "log.txt",
        script_dir / "logs" / "alt1" / "training.log",
    ]
    log_path = None
    for c in candidates:
        if c.exists():
            log_path = str(c)
            break
    if log_path is None:
        print("Error: Could not find log.txt or logs/alt1/training.log")
        exit(1)

    print(f"Parsing: {log_path}")
    data = parse_log(log_path)
    print(f"Found {len(data['epochs'])} epochs")
    if data["nmse_ideal"] is not None:
        print(f"NMSE vs ideal H : {data['nmse_ideal']:.2f} dB")
    if data["nmse_pract"] is not None:
        print(f"NMSE vs pract H : {data['nmse_pract']:.2f} dB")

    output = str(script_dir / "training_metrics_plot.png")
    plot_all(data, output)
