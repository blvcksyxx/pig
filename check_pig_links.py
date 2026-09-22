#!/usr/bin/env python3

import sys
import urllib.error
import urllib.request


def check_url(name: str, url: str) -> tuple[bool, str]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "pig-url-checker/1.0",
            "Range": "bytes=0-0",
        },
        method="GET",
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read(1)

            status = response.status
            final_url = response.geturl()
            content_type = response.headers.get("Content-Type", "unknown")

            ok = 200 <= status < 400
            state = "OK" if ok else "BAD"

            print(f"[{state}] {name}")
            print(f"  status: {status}")
            print(f"  type:   {content_type}")
            print(f"  final:  {final_url}")
            print()

            return ok, state

    except urllib.error.HTTPError as exc:
        print(f"[BAD] {name}")
        print(f"  status: {exc.code} {exc.reason}")
        print(f"  url:    {url}")
        print()
        return False, "BAD"

    except urllib.error.URLError as exc:
        print(f"[BAD] {name}")
        print(f"  error:  {exc.reason}")
        print(f"  url:    {url}")
        print()
        return False, "BAD"

    except TimeoutError:
        print(f"[BAD] {name}")
        print("  error:  timeout")
        print(f"  url:    {url}")
        print()
        return False, "BAD"

    except Exception as exc:
        print(f"[BAD] {name}")
        print(f"  error:  {exc}")
        print(f"  url:    {url}")
        print()
        return False, "BAD"


def parse_dictionary(path: str) -> list[tuple[str, str]]:
    entries = []

    with open(path, "r", encoding="utf-8") as file:
        for line_number, raw_line in enumerate(file, 1):
            line = raw_line.strip()

            if not line or line.startswith("#"):
                continue

            if "::" not in line:
                print(
                    f"[SKIP] line {line_number}: "
                    f"expected name::url"
                )
                continue

            name, url = line.split("::", 1)
            name = name.strip()
            url = url.strip()

            if not name or not url:
                print(f"[SKIP] line {line_number}: empty name or url")
                continue

            entries.append((name, url))

    return entries


def main() -> int:
    dictionary = sys.argv[1] if len(sys.argv) > 1 else "pig.txt"

    try:
        entries = parse_dictionary(dictionary)
    except OSError as exc:
        print(f"error: cannot read {dictionary}: {exc}")
        return 1

    if not entries:
        print("no entries found")
        return 1

    print(f"checking {len(entries)} links from {dictionary}...")
    print()

    passed = 0
    failed = 0

    for name, url in entries:
        ok, _ = check_url(name, url)

        if ok:
            passed += 1
        else:
            failed += 1

    print("=" * 60)
    print(f"total:  {len(entries)}")
    print(f"valid:  {passed}")
    print(f"broken: {failed}")

    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
