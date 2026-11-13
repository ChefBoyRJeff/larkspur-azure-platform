import pathlib
import sys

# Make the app package importable when pytest runs from the repository root.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
