#!/usr/bin/env python3
"""Compat: same formatter as agent-human-stream.py."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name("agent-human-stream.py")), run_name="__main__")
