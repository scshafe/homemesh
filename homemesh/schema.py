"""JSON Schema export of the house model (the front end's types come from it)."""

import json
import sys

from .model import House


def house_schema() -> dict:
    return House.model_json_schema()


if __name__ == "__main__":
    json.dump(house_schema(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
