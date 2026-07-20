#!/usr/bin/env python3
"""Check whether GitHub has replaced a known expired Actions TLS certificate."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import hashlib
import socket
import ssl
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


DEFAULT_PORT = 443
EXPIRED_SHA256 = (
    "6F379AEDB18C119B63E39E07794C77BF77C47FB8C07401842CC12A3A18C366A1"
)
KNOWN_US_STAMPS = (*range(1, 16), *range(20, 27))
KNOWN_US_ENDPOINTS = tuple(
    f"pipelinesghubeus{stamp}.actions.githubusercontent.com"
    for stamp in KNOWN_US_STAMPS
)


@dataclass(frozen=True)
class CertificateResult:
    host: str
    certificate: dict[str, Any] | None = None
    fingerprint: str | None = None
    not_before: datetime | None = None
    not_after: datetime | None = None
    fingerprint_changed: bool = False
    date_valid: bool = False
    tls_valid: bool = False
    tls_message: str = "not checked"
    error: str | None = None

    @property
    def usable_replacement(self) -> bool:
        return self.fingerprint_changed and self.date_valid and self.tls_valid


def normalized_fingerprint(value: str) -> str:
    return "".join(character for character in value.upper() if character in "0123456789ABCDEF")


def format_fingerprint(value: str) -> str:
    return ":".join(value[index : index + 2] for index in range(0, len(value), 2))


def distinguished_name(entries: Any) -> str:
    parts: list[str] = []
    for relative_name in entries or ():
        for key, value in relative_name:
            parts.append(f"{key}={value}")
    return ", ".join(parts) or "unknown"


def certificate_datetime(value: str) -> datetime:
    return datetime.fromtimestamp(ssl.cert_time_to_seconds(value), timezone.utc)


def fetch_certificate(host: str, port: int, timeout: float) -> tuple[bytes, dict[str, Any]]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    with socket.create_connection((host, port), timeout=timeout) as connection:
        with context.wrap_socket(connection, server_hostname=host) as tls_connection:
            certificate_der = tls_connection.getpeercert(binary_form=True)

    certificate_pem = ssl.DER_cert_to_PEM_cert(certificate_der)
    with tempfile.NamedTemporaryFile("w", suffix=".pem", encoding="ascii") as certificate_file:
        certificate_file.write(certificate_pem)
        certificate_file.flush()
        certificate = ssl._ssl._test_decode_cert(certificate_file.name)  # type: ignore[attr-defined]

    return certificate_der, certificate


def verify_tls(host: str, port: int, timeout: float) -> tuple[bool, str]:
    context = ssl.create_default_context()
    try:
        with socket.create_connection((host, port), timeout=timeout) as connection:
            with context.wrap_socket(connection, server_hostname=host):
                return True, "certificate is trusted and valid for this host"
    except ssl.SSLCertVerificationError as error:
        return False, f"certificate verification failed: {error.verify_message}"
    except (OSError, ssl.SSLError) as error:
        return False, f"TLS connection failed: {error}"


def inspect_endpoint(
    host: str,
    port: int,
    timeout: float,
    old_fingerprint: str,
    checked_at: datetime,
) -> CertificateResult:
    try:
        certificate_der, certificate = fetch_certificate(host, port, timeout)
        fingerprint = hashlib.sha256(certificate_der).hexdigest().upper()
        not_before = certificate_datetime(certificate["notBefore"])
        not_after = certificate_datetime(certificate["notAfter"])
        tls_valid, tls_message = verify_tls(host, port, timeout)
    except (KeyError, OSError, ssl.SSLError, ValueError) as error:
        return CertificateResult(host=host, error=str(error))

    return CertificateResult(
        host=host,
        certificate=certificate,
        fingerprint=fingerprint,
        not_before=not_before,
        not_after=not_after,
        fingerprint_changed=fingerprint != old_fingerprint,
        date_valid=not_before <= checked_at <= not_after,
        tls_valid=tls_valid,
        tls_message=tls_message,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Check whether GitHub replaced the expired TLS certificate served by "
            "a GitHub Actions pipeline endpoint."
        )
    )
    parser.add_argument(
        "--host",
        dest="hosts",
        action="append",
        help=(
            "Actions hostname to inspect; repeat for multiple hosts. "
            "The default checks every known pipelinesghubeus endpoint."
        ),
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TLS port")
    parser.add_argument("--timeout", type=float, default=10.0, help="connection timeout in seconds")
    parser.add_argument("--workers", type=int, default=8, help="maximum concurrent endpoint checks")
    parser.add_argument("--verbose", action="store_true", help="print full certificate details")
    parser.add_argument(
        "--old-fingerprint",
        default=EXPIRED_SHA256,
        help="SHA-256 fingerprint of the certificate being replaced",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    hosts = tuple(dict.fromkeys(arguments.hosts or KNOWN_US_ENDPOINTS))
    old_fingerprint = normalized_fingerprint(arguments.old_fingerprint)
    if len(old_fingerprint) != 64:
        print("Error: --old-fingerprint must contain exactly 64 hexadecimal digits.", file=sys.stderr)
        return 2
    if not hosts:
        print("Error: at least one endpoint is required.", file=sys.stderr)
        return 2
    if arguments.workers < 1:
        print("Error: --workers must be at least 1.", file=sys.stderr)
        return 2

    checked_at = datetime.now(timezone.utc)
    with ThreadPoolExecutor(max_workers=min(arguments.workers, len(hosts))) as executor:
        results = list(
            executor.map(
                lambda host: inspect_endpoint(
                    host,
                    arguments.port,
                    arguments.timeout,
                    old_fingerprint,
                    checked_at,
                ),
                hosts,
            )
        )

    host_width = max(len("HOST"), *(len(result.host) for result in results))
    print(f"Checked at: {checked_at.isoformat()}")
    print(f"Known expired fingerprint: {format_fingerprint(old_fingerprint)}")
    print()
    print(
        f"{'HOST':<{host_width}}  {'RESULT':<9}  {'TLS':<6}  "
        f"{'VALID UNTIL (UTC)':<20}  FINGERPRINT"
    )
    print(f"{'-' * host_width}  {'-' * 9}  {'-' * 6}  {'-' * 20}  {'-' * 23}")

    for result in results:
        if result.error:
            status = "ERROR"
            tls_status = "error"
            valid_until = "unknown"
            fingerprint = "unknown"
        else:
            status = (
                "UPDATED"
                if result.usable_replacement
                else "EXPIRED"
                if not result.fingerprint_changed
                else "INVALID"
            )
            tls_status = "pass" if result.tls_valid else "fail"
            valid_until = result.not_after.strftime("%Y-%m-%d %H:%M:%S")
            fingerprint = format_fingerprint(result.fingerprint)[:23]

        print(
            f"{result.host:<{host_width}}  {status:<9}  {tls_status:<6}  "
            f"{valid_until:<20}  {fingerprint}"
        )

        if arguments.verbose:
            if result.error:
                print(f"  Error: {result.error}")
            else:
                print(f"  Subject: {distinguished_name(result.certificate.get('subject'))}")
                print(f"  Issuer: {distinguished_name(result.certificate.get('issuer'))}")
                print(f"  Serial: {result.certificate.get('serialNumber', 'unknown')}")
                print(f"  Valid from: {result.not_before.isoformat()}")
                print(f"  Valid until: {result.not_after.isoformat()}")
                print(f"  SHA-256 fingerprint: {format_fingerprint(result.fingerprint)}")
                print(f"  TLS validation: {result.tls_message}")

    usable_count = sum(result.usable_replacement for result in results)
    unchanged_count = sum(
        not result.error and not result.fingerprint_changed for result in results
    )
    invalid_count = sum(
        not result.error and result.fingerprint_changed and not result.usable_replacement
        for result in results
    )
    error_count = sum(result.error is not None for result in results)

    print()
    print(
        f"Summary: {usable_count} updated and usable, {unchanged_count} unchanged, "
        f"{invalid_count} changed but invalid, {error_count} errors."
    )

    if error_count:
        return 2
    if usable_count == len(results):
        print("Result: every known U.S. endpoint has a usable replacement certificate.")
        return 0
    print("Result: one or more U.S. endpoints still lack a usable replacement certificate.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
