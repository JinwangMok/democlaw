#!/usr/bin/env python3
"""Hello World custom skill for OpenClaw.
Demonstrates the simplest possible custom skill.
"""
import sys
import json

def main():
    # Read input from stdin (OpenClaw passes JSON)
    input_data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}
    name = input_data.get("name", "World")

    # Return result as JSON to stdout
    result = {"message": f"Hello, {name}! This is a custom OpenClaw skill."}
    print(json.dumps(result))

if __name__ == "__main__":
    main()
