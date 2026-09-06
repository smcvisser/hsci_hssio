#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["jinja2>=3.1"]
# ///
"""
build_demo.py -- het enige script dat je voor de demo hoeft te draaien.

    uv run demo/build_demo.py

Wat het doet, in volgorde:

  1. demo_config.json lezen en omzetten naar een Tcl-configblok
  2. Vivado batch draaien met vivado/hsci_demo_gen.tcl:
       - de acht HSCI-pinnen analyseren tegen de echte device database
       - de twee High Speed SelectIO Wizard instanties afleiden en aanmaken
       - de MMCM, de JTAG-AXI master en de AXI-Lite klokconverter aanmaken
       - de voorspelde port map toetsen aan de gegenereerde .veo
       - alle feiten wegschrijven als generated/hsci_facts.json
  3. uit die feiten met Jinja de RTL renderen:
       - hsci_phy_top.sv    de PHY met exact de poorten die ADI's axi_hsci wil
       - hsci_demo_top.sv   toplevel met klokken, JTAG-AXI, CDC en axi_hsci
       - hsci_demo_pins.xdc pinnen, klokken en de VCCO-eis
       - hsci_demo_srcs.tcl de bestandslijst voor Vivado

Met --check draait er daarna nog een out-of-context synthese over het toplevel,
zodat je weet dat het gegenereerde geheel ook echt elaboreert.

    uv run demo/build_demo.py --clean --check   schone build van nul af
    uv run demo/build_demo.py --project         maakt een .xpr voor de Vivado GUI
    uv run demo/build_demo.py --clean-only      alleen generated/ weggooien
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
# Vivado vinden
# ---------------------------------------------------------------------------
def find_vivado(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("VIVADO"):
        return os.environ["VIVADO"]
    found = shutil.which("vivado")
    if found:
        return found
    # Windows-installaties: C:/Xilinx/<versie>/Vivado/bin/vivado.bat
    cands = sorted(glob.glob("C:/Xilinx/*/Vivado/bin/vivado.bat"), reverse=True)
    if cands:
        return cands[0]
    sys.exit(
        "vivado niet gevonden. Zet $env:VIVADO of geef --vivado mee, "
        "bijvoorbeeld C:/Xilinx/2025.1/Vivado/bin/vivado.bat"
    )


# ---------------------------------------------------------------------------
# opruimen
# ---------------------------------------------------------------------------
def clean() -> None:
    """Gooit generated/ weg -- alles wat dit script en Vivado erin schrijven.

    Dat is de RTL, de XDC, hsci_facts.json, demo_cfg.tcl, de logs, en de
    Vivado-mappen .srcs/, .gen/ en .Xil/ met de vijf IP's erin. Blijft staan:
    demo_config.json en templates/ (dat is bron, geen resultaat) en
    src/adi-hdl (een clone, niet iets wat wij genereren).
    """
    # Vangnet: nooit iets anders weggooien dan precies demo/generated.
    if GEN.parent != HERE or GEN.name != "generated":
        sys.exit(f"weiger te verwijderen: {GEN} is niet demo/generated")
    if not GEN.exists():
        print(f"  niets te doen, {GEN.name}/ bestaat niet")
        return

    files = [f for f in GEN.rglob("*") if f.is_file()]
    mb = sum(f.stat().st_size for f in files) / 1e6
    shutil.rmtree(GEN)
    print(f"  weg: {GEN}  ({len(files)} bestanden, {mb:.1f} MB)")


# ---------------------------------------------------------------------------
# config -> Tcl
# ---------------------------------------------------------------------------
def write_tcl_config(cfg: dict, path: Path) -> None:
    """Vivado's Tcl kent geen JSON, dus we schrijven een plat configblok."""
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
    lines = ["# GEGENEREERD door build_demo.py -- niet met de hand aanpassen.\n"]
    lines += [f"set demo({k}) {{{v}}}\n" for k, v in flat.items()]
    path.write_text("".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Vivado draaien
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
                            "  MMCM", "  JTAG", "  AXI ", "  WAARSCHUWING",
                            "  gesch", "  reden", "  remedie", "ERROR", "****")):
            print("  " + line)
    if proc.returncode != 0:
        sys.exit(f"\nVivado faalde (exit {proc.returncode}). Volledig log: {log}")


# ---------------------------------------------------------------------------
# renderen
# ---------------------------------------------------------------------------
def render(facts: dict, cfg: dict) -> None:
    env = Environment(
        loader=FileSystemLoader(HERE / "templates"),
        undefined=StrictUndefined,      # een typo in een template is een fout
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )
    ctx = dict(facts)
    ctx["adi_rel"] = os.path.relpath(ADI, GEN).replace("\\", "/")
    ctx["config_note"] = cfg["hsci"].get("_force_rate_reden", "")

    for tmpl, out in [
        ("hsci_phy_top.sv.j2", "hsci_phy_top.sv"),
        ("hsci_demo_top.sv.j2", "hsci_demo_top.sv"),
        ("hsci_demo_pins.xdc.j2", "hsci_demo_pins.xdc"),
        ("hsci_demo_srcs.tcl.j2", "hsci_demo_srcs.tcl"),
    ]:
        text = env.get_template(tmpl).render(**ctx)
        (GEN / out).write_text(text, encoding="utf-8", newline="\n")
        print(f"  gerenderd: generated/{out}")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(HERE / "demo_config.json"))
    ap.add_argument("--vivado", default=None, help="pad naar vivado(.bat)")
    ap.add_argument("--skip-vivado", action="store_true",
                    help="alleen renderen uit de bestaande generated/hsci_facts.json")
    ap.add_argument("--check", action="store_true",
                    help="na het genereren een out-of-context synthese draaien")
    ap.add_argument("--project", action="store_true",
                    help="een Vivado-project op schijf zetten (.xpr) om in de GUI te openen")
    ap.add_argument("--clean", action="store_true",
                    help="generated/ eerst helemaal weggooien en daarna opnieuw bouwen")
    ap.add_argument("--clean-only", action="store_true",
                    help="alleen generated/ weggooien en stoppen")
    args = ap.parse_args()

    # Eerst weigeren, dan pas weggooien -- andersom ben je je facts.json kwijt
    # aan een aanroep die toch afbreekt.
    if args.clean and args.skip_vivado:
        sys.exit("--clean en --skip-vivado gaan niet samen: --clean gooit juist "
                 "de hsci_facts.json weg waar --skip-vivado uit rendert")

    if args.clean or args.clean_only:
        print("\n== opruimen ==")
        clean()
        if args.clean_only:
            return

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    GEN.mkdir(exist_ok=True)
    facts_path = GEN / "hsci_facts.json"

    if not args.skip_vivado:
        if not (ADI / "axi_hsci" / "axi_hsci.sv").exists():
            sys.exit(f"ADI's axi_hsci niet gevonden onder {ADI}.\n"
                     "Haal hem op met:\n"
                     "  git clone --filter=blob:none --sparse --depth 1 "
                     "https://github.com/analogdevicesinc/hdl.git src/adi-hdl\n"
                     "  cd src/adi-hdl && git sparse-checkout set "
                     "library/axi_hsci library/common library/util_cdc "
                     "library/scripts library/xilinx")

        tcl_cfg = GEN / "demo_cfg.tcl"
        write_tcl_config(cfg, tcl_cfg)
        print("\n== 1/3  IP genereren met Vivado ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_gen.tcl",
                   [str(tcl_cfg), str(facts_path)],
                   cwd=GEN, log=GEN / "gen.log")

    if not facts_path.exists():
        sys.exit(f"{facts_path} bestaat niet -- draai eerst zonder --skip-vivado")

    facts = json.loads(facts_path.read_text(encoding="utf-8"))
    print("\n== 2/3  RTL renderen met Jinja ==")
    render(facts, cfg)

    if args.project:
        print("\n== Vivado-project op schijf zetten ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_project.tcl",
                   [facts["part"], str(GEN)],
                   cwd=GEN, log=GEN / "project.log")

    if args.check:
        print("\n== 3/3  Out-of-context synthese ==")
        run_vivado(find_vivado(args.vivado),
                   HERE / "vivado" / "hsci_demo_check.tcl",
                   [facts["part"], str(GEN)],
                   cwd=GEN, log=GEN / "check.log")
    else:
        print("\n== 3/3  overgeslagen (gebruik --check voor een synthesecontrole) ==")

    xpr = GEN / "vivado_project" / "hsci_demo.xpr"
    project_line = (f"  vivado_project/     open in de GUI met:  vivado {xpr}\n"
                    if args.project else
                    "  (geen .xpr -- draai met --project als je het in de GUI wilt openen)\n")
    print(f"""
klaar. In {GEN}:

  hsci_phy_top.sv     PHY, poorten exact zoals axi_hsci ze wil
  hsci_demo_top.sv    toplevel: MMCM, JTAG-AXI, AXI-Lite CDC, axi_hsci, PHY
  hsci_demo_pins.xdc  pinnen en klokken
  hsci_demo_srcs.tcl  bestandslijst; source dit in een Vivado-project
  hsci_facts.json     wat de analyse heeft opgeleverd
{project_line}""")


if __name__ == "__main__":
    main()
