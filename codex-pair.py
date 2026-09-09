#!/usr/bin/env python3
"""Create a Codex pairing code with a configurable response timeout.

Requires Python 3.11+ and websockets 13+:
    python3 -m pip install 'websockets>=13'
"""

import argparse
import asyncio
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import sys


class PairingError(Exception):
    pass


def positive_seconds(value):
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("timeout must be a positive number") from None
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("timeout must be a finite positive number")
    return seconds


def parse_args():
    codex_home = Path(os.environ.get("CODEX_HOME") or "~/.codex").expanduser()
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--timeout", type=positive_seconds, default=30,
                        metavar="SECONDS", help="pairing response timeout (default: 30)")
    parser.add_argument("--socket", type=Path,
                        default=codex_home / "app-server-control/app-server-control.sock",
                        help="override the local app-server Unix socket path")
    parser.add_argument("--json", action="store_true", help="print the complete result as JSON")
    return parser.parse_args()


async def request(connection, request_id, method, params, timeout):
    try:
        async with asyncio.timeout(timeout):
            await connection.send(json.dumps({"id": request_id, "method": method, "params": params}))
            while True:
                message = json.loads(await connection.recv())
                if not isinstance(message, dict):
                    raise PairingError("Background server returned an invalid JSON-RPC message")
                if message.get("id") != request_id:
                    continue
                if "error" in message:
                    raise PairingError(f"{method}: {json.dumps(message['error'], ensure_ascii=False)}")
                if not isinstance(message.get("result"), dict):
                    raise PairingError(f"{method}: missing or invalid result")
                return message["result"]
    except TimeoutError:
        raise PairingError(f"{method}: no response within {timeout:g} seconds") from None


async def pair(args, unix_connect):
    socket_path = args.socket.expanduser()
    if not socket_path.is_socket():
        raise PairingError(f"No app-server socket at {socket_path}. Start it with: codex remote-control start")
    async with unix_connect(str(socket_path), uri="ws://localhost", compression=None,
                            open_timeout=10, close_timeout=1) as connection:
        await request(connection, 1, "initialize", {
            "clientInfo": {"name": "codex_pair_script", "version": "1.0"},
            "capabilities": {"experimentalApi": True},
        }, 10)
        async with asyncio.timeout(10):
            await connection.send(json.dumps({"method": "initialized"}))
        return await request(connection, 2, "remoteControl/pairing/start",
                             {"manualCode": True}, args.timeout)


def main():
    args = parse_args()
    if sys.version_info < (3, 11):
        print("Error: Python 3.11 or newer is required", file=sys.stderr)
        return 1
    try:
        from websockets.asyncio.client import unix_connect
        from websockets.exceptions import WebSocketException
    except ImportError:
        print("Error: Install the dependency with: python3 -m pip install 'websockets>=13'", file=sys.stderr)
        return 1
    try:
        result = asyncio.run(pair(args, unix_connect))
        if args.json:
            print(json.dumps(result, ensure_ascii=False))
        else:
            code = result.get("manualPairingCode") or result.get("pairingCode")
            if not code:
                raise PairingError("Background server returned no pairing code")
            expires = result.get("expiresAt")
            try:
                expiry = datetime.fromtimestamp(expires, timezone.utc).isoformat()
            except (TypeError, ValueError, OverflowError, OSError):
                expiry = str(expires)
            print(f"Pairing code: {code}")
            print(f"Expires at: {expiry}")
        return 0
    except TimeoutError:
        print("Error: Connection or initialization timed out after 10 seconds", file=sys.stderr)
        return 1
    except (PairingError, OSError, WebSocketException, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
