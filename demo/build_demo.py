#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["jinja2>=3.1"]
# ///
"""
build_demo.py -- the only script you need to run for the demo.

    uv run demo/build_demo.py

What it does, in order:

  1. read demo_config.json and turn it into a Tcl config block
  2. run Vivado batch with vivado/hsci_demo_gen.tcl:
       - analyze the eight HSCI pins against the real device database
       - derive and create the two High Speed SelectIO Wizard instances
       - create the MMCM, the JTAG-AXI master and the AXI-Lite clock converter
       - check the predicted port map against the generated .veo
       - write out all the facts as generated/hsci_facts.json
  3. render the RTL from those facts with Jinja:
       - hsci_phy_top.sv    the PHY with exactly the ports ADI's axi_hsci wants
       - hsci_demo_top.sv   top level with clocks, JTAG-AXI, CDC and axi_hsci
       - hsci_demo_pins.xdc pins, clocks and the VCCO requirement
       - hsci_demo_srcs.tcl the file list for Vivado

With --check it then also runs an out-of-context synthesis over the top level,
so you know the generated whole actually elaborates.

    uv run demo/build_demo.py --clean --check   clean build from scratch
    uv run demo/build_demo.py --project         makes a .xpr for the Vivado GUI
    uv run demo/build_demo.py --clean-only      only deletes generated/ and __pycache__
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
GEN = HERE / "generated"
ADI = REPO / "src" / "adi-hdl" / "library"


# ---------------------------------------------------------------------------
# finding Vivado
# ---------------------------------------------------------------------------
def find_vivado(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("VIVADO"):
        return os.environ["VIVADO"]
    found = shutil.which("vivado")
    if found:
        return found
    # Windows installs: C:/Xilinx/<version>/Vivado/bin/vivado.bat
    cands = sorted(glob.glob("C:/Xilinx/*/Vivado/bin/vivado.bat"), reverse=True)
    if cands:
        return cands[0]
    sys.exit(
        "vivado not found. Set $env:VIVADO or pass --vivado, "
        "e.g. C:/Xilinx/2025.1/Vivado/bin/vivado.bat"
    )


# ---------------------------------------------------------------------------
# cleaning
# ---------------------------------------------------------------------------
def clean() -> None:
    """Deletes generated/ -- everything this script and Vivado write into it.

    That's the RTL, the XDC, hsci_facts.json, demo_cfg.tcl, the logs, and the
    Vivado directories .srcs/, .gen/ and .Xil/ with the five IPs in them.
    Also removes demo/__pycache__ (bytecode Python leaves behind).
    Left alone: demo_config.json and templates/ (that's source, not output)
    and src/adi-hdl (a clone, not something we generate).
    """
    # Safety net: never delete anything other than exactly demo/generated
    # and demo/__pycache__.
    if GEN.parent != HERE or GEN.name != "generated":
        sys.exit(f"refusing to delete: {GEN} is not demo/generated")
    if not GEN.exists() and not (HERE / "__pycache__").is_dir():
        print(f"  nothing to do, {GEN.name}/ doesn't exist")
        return

    if GEN.exists():
        files = [f for f in GEN.rglob("*") if f.is_file()]
        mb = sum(f.stat().st_size for f in files) / 1e6
        shutil.rmtree(GEN)
        print(f"  removed: {GEN}  ({len(files)} files, {mb:.1f} MB)")

    pycache = HERE / "__pycache__"
    if pycache.is_dir():
        shutil.rmtree(pycache)
        print(f"  removed: {pycache}")


# ---------------------------------------------------------------------------
# config -> Tcl
# ---------------------------------------------------------------------------
def write_tcl_config(cfg: dict, path: Path) -> None:
    """Vivado's Tcl doesn't know JSON, so we write a flat config block."""
    hsci, tx, rx = cfg["hsci"], cfg["hsci"]["tx"], cfg["hsci"]["rx"]
    clk, axi, ips = cfg["clocking"], cfg["axi"], cfg["ip_names"]

    flat = {
        "part": cfg["part"],
        "data_speed": hsci["data_speed"],
        "ref_freq": f'{hsci["ref_freq"]:.3f}',
        "rx_clk_to_data": hsci["rx_clk_to_data"],
        "force_rate": 1 if hsci["force_rate"] else 0,
        "clk_source": "BUFG_TO_PLL",
        "tx_clk_p": tx["clk_p"], "tx_clk_n": tx["clk_n"],
        "tx_dat_p": tx["dat_p"], "tx_dat_n": tx["dat_n"],
        "rx_clk_p": rx["clk_p"], "rx_clk_n": rx["clk_n"],
        "rx_dat_p": rx["dat_p"], "rx_dat_n": rx["dat_n"],
        "tx_sig_clk_p": tx["sig_clk_p"], "tx_sig_clk_n": tx["sig_clk_n"],
        "tx_sig_dat_p": tx["sig_dat_p"], "tx_sig_dat_n": tx["sig_dat_n"],
        "rx_sig_clk_p": rx["sig_clk_p"], "rx_sig_clk_n": rx["sig_clk_n"],
        "rx_sig_dat_p": rx["sig_dat_p"], "rx_sig_dat_n": rx["sig_dat_n"],
        "sys_clk_p": clk["sys_clk_p"], "sys_clk_n": clk["sys_clk_n"],
        "sys_clk_mhz": f'{clk["sys_clk_mhz"]:.3f}',
        "sys_clk_iostandard": clk["sys_clk_iostandard"],
        "mmcm_out_ref_mhz": f'{clk["mmcm_out_ref_mhz"]:.3f}',
        "mmcm_out_axi_mhz": f'{clk["mmcm_out_axi_mhz"]:.3f}',
        "axi_addr_width": axi["addr_width"],
        "axi_data_width": axi["data_width"],
        "ip_tx": ips["tx"], "ip_rx": ips["rx"], "ip_mmcm": ips["mmcm"],
        "ip_jtag": ips["jtag_axi"], "ip_cdc": ips["axi_cdc"],
    }
    lines = ["# GENERATED by build_demo.py -- do not edit by hand.\n"]
    lines += [f"set demo({k}) {{{v}}}\n" for k, v in flat.items()]
    path.write_text("".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# running Vivado
# ---------------------------------------------------------------------------
def run_vivado(vivado: str, script: Path, args: list[str], cwd: Path, log: Path) -> None:
    cmd = [vivado, "-mode", "batch", "-nojournal", "-notrace",
           "-source", str(script), "-tclargs", *args]
    print(f"  $ {' '.join(cmd)}")
    with log.open("w", encoding="utf-8") as fh:
        proc = subprocess.run(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT,
                              text=True)
    text = log.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        if line.startswith(("=====", "ok ", "  ok", "  !!", "  TX ", "  RX ",
                            "  MMCM", "  JTAG", "  AXI ", "  WARNING",
                            "  writ", "  reason", "  fix", "ERROR", "****")):
            print("  " + line)
    if proc.returncode != 0:
        sys.exit(f"\nVivado failed (exit {proc.returncode}). Full log: {log}")


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
def render(facts: dict, cfg: dict) -> None:
    env = Environment(
        loader=FileSystemLoader(HERE / "templates"),
        undefined=StrictUndefined,      # a typo in a template is an error
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )
    ctx = dict(facts)
    ctx["adi_rel"] = os.path.relpath(ADI, GEN).replace("\\", "/")
    ctx["config_note"] = cfg["hsci"].get("_force_rate_reason", "")

    for tmpl, out in [
        ("hsci_phy_top.sv.j2", "hsci_phy_top.sv"),
        ("hsci_demo_top.sv.j2", "hsci_demo_top.sv"),
        ("hsci_demo_pins.xdc.j2", "hsci_demo_pins.xdc"),
        ("hsci_demo_srcs.tcl.j2", "hsci_demo_srcs.tcl"),
    ]:
        text = env.get_template(tmpl).render(**ctx)
        (GEN / out).write_text(text, encoding="utf-8", newline="\n")
        print(f"  rendered: generated/{out}")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(HERE / "demo_config.json"))
    ap.add_argument("--vivado", default=None, help="path to vivado(.bat)")
    ap.add_argument("--skip-vivado", action="store_true",
                    help="only render from the existing generated/hsci_facts.json")
    ap.add_argument("--check", action="store_true",
                    help="run an out-of-context synthesis after generating")
    ap.add_argument("--project", action="store_true",
                    help="write a Vivado project to disk (.xpr) to open in the GUI")
    ap.add_argument("--clean", action="store_true",
                    help="delete generated/ and __pycache__ first, then build again")
    ap.add_argument("--clean-only", action="store_true",
                    help="only delete generated/ and __pycache__, then stop")
    args = ap.parse_args()

    # Refuse first, delete only after -- the other way round you'd lose your
    # facts.json to a call that aborts anyway.
    if args.clean and args.skip_vivado:
        sys.exit("--clean and --skip-vivado don't mix: --clean deletes exactly "
                 "the hsci_facts.json that --skip-vivado renders from")

    if args.clean or args.clean_only:
        print("\n== cleaning ==")
        clean()
        if args.clean_only:
            return

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    GEN.mkdir(exist_ok=True)
    facts_path = GEN / "hsci_facts.json"

    if not args.skip_vivado:
        if not (ADI / "axi_hsci" / "axi_hsci.sv").exists():
            sys.exit(f"ADI's axi_hsci not found under {ADI}.\n"
                     "Fetch it with:\n"
                     "  git clone --filter=blob:none --sparse --depth 1 "
                     "https://github.com/analogdevicesinc/hdl.git src/adi-hdl\n"
                     "  cd src/adi-hdl && git sparse-checkout set "
                     "library/axi_hsci library/common library/util_cdc "
                     "library/scripts library/xilinx")

        tcl_cfg = GEN / "demo_cfg.tcl"
        write_tcl_config(cfg, tcl_cfg)
        print("\n== 1/3  generating IP with Vivado ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_gen.tcl",
                   [str(tcl_cfg), str(facts_path)],
                   cwd=GEN, log=GEN / "gen.log")

    if not facts_path.exists():
        sys.exit(f"{facts_path} doesn't exist -- run without --skip-vivado first")

    facts = json.loads(facts_path.read_text(encoding="utf-8"))
    print("\n== 2/3  rendering RTL with Jinja ==")
    render(facts, cfg)

    if args.project:
        print("\n== writing Vivado project to disk ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_project.tcl",
                   [facts["part"], str(GEN)],
                   cwd=GEN, log=GEN / "project.log")

    if args.check:
        print("\n== 3/3  out-of-context synthesis ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_check.tcl",
                   [facts["part"], str(GEN)],
                   cwd=GEN, log=GEN / "check.log")
    else:
        print("\n== 3/3  skipped (use --check for a synthesis check) ==")

    xpr = GEN / "vivado_project" / "hsci_demo.xpr"
    project_line = (f"  vivado_project/     open in the GUI with:  vivado {xpr}\n"
                    if args.project else
                    "  (no .xpr -- run with --project if you want to open it in the GUI)\n")
    print(f"""
done. In {GEN}:

  hsci_phy_top.sv     PHY, ports exactly as axi_hsci wants them
  hsci_demo_top.sv    top level: MMCM, JTAG-AXI, AXI-Lite CDC, axi_hsci, PHY
  hsci_demo_pins.xdc  pins and clocks
  hsci_demo_srcs.tcl  file list; source this in a Vivado project
  hsci_facts.json     what the analysis produced
{project_line}""")


if __name__ == "__main__":
    main()
