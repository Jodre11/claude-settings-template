#!/usr/bin/env python3
"""sso-cache-check.py — AWS SSO cache walker for token validity checks.

  --mode expiry  Prints "valid" (token not expired within grace) or "expired".

Usage:
  sso-cache-check.py --cache-dir DIR --start-url URL --mode expiry [--grace-seconds N]
"""

import argparse
import glob
import json
import os
from datetime import datetime, timedelta, timezone


def find_tokens(cache_dir, start_url):
    """Yield (path, data) for SSO cache files matching start_url with an accessToken."""
    for path in glob.glob(os.path.join(cache_dir, "*.json")):
        try:
            with open(path) as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        if data.get("startUrl") != start_url:
            continue
        if "accessToken" not in data:
            continue
        yield path, data


def check_expiry(cache_dir, start_url, grace_seconds):
    """Print 'valid' if any token is valid beyond grace period, else 'expired'."""
    grace = timedelta(seconds=grace_seconds)
    now = datetime.now(timezone.utc)

    for _path, data in find_tokens(cache_dir, start_url):
        expires_str = data.get("expiresAt", "")
        try:
            expires_str = expires_str.replace("Z", "+00:00")
            expires = datetime.fromisoformat(expires_str)
            if expires - grace > now:
                print("valid")
                return
        except (ValueError, TypeError):
            continue

    print("expired")


def main():
    parser = argparse.ArgumentParser(description="AWS SSO cache walker")
    parser.add_argument("--cache-dir", required=True, help="Path to SSO cache directory")
    parser.add_argument("--start-url", required=True, help="SSO start URL to match")
    parser.add_argument("--mode", required=True, choices=["expiry"], help="Check mode")
    parser.add_argument("--grace-seconds", type=int, default=300, help="Grace period for expiry check")
    args = parser.parse_args()

    cache_dir = os.path.expanduser(args.cache_dir)

    check_expiry(cache_dir, args.start_url, args.grace_seconds)


if __name__ == "__main__":
    main()
