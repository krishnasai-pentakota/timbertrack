"""Shared settings for the tests and the demo builder. Override with environment variables."""
import os, pathlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
DSN = os.environ.get("TT_DSN", "host=/tmp port=54329 user=postgres dbname=aditya")
CHROME = os.environ.get("TT_CHROME", "/usr/bin/google-chrome")
VENDOR = pathlib.Path(os.environ.get("TT_VENDOR", ROOT / "tests" / "vendor"))   # filled by tests/fetch_vendor.sh
SBJS = str(VENDOR / "supabase.js")
XLSX = str(VENDOR / "xlsx.full.min.js")
JSPDF = str(VENDOR / "jspdf.umd.min.js")
AUTOT = str(VENDOR / "jspdf.plugin.autotable.min.js")
APP = str(ROOT / "app" / "index.html")
WORKBOOK = str(ROOT / "tests" / "db" / "workbook_tally_counts.json")
SLIP_IMG = str(ROOT / "demo" / "test_assets" / "sample_slip.png")
DRIVER_IMG = str(ROOT / "demo" / "test_assets" / "sample_driver.png")


def reset_db():
    """Fresh database with the final schema (tests/reset_db.sh)."""
    subprocess.run(["bash", str(ROOT / "tests" / "reset_db.sh")], check=True, capture_output=True)
