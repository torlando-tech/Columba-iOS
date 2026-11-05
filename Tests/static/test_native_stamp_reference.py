"""Compare production Swift PoW with Python RNS and an enforcing LXMF receiver.

Run on macOS with host cryptography/pyserial and the pinned pure RNS/LXMF packages
on PYTHONPATH. Each receiver runs in a subprocess, without network interfaces.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


def native_stamp(library, workblock, target):
    start = library.columba_stamp_job_start_target
    start.argtypes = [ctypes.c_char_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]
    start.restype = ctypes.c_uint64
    poll = library.columba_stamp_job_poll
    poll.argtypes = [ctypes.c_uint64, ctypes.c_char_p]
    poll.restype = ctypes.c_int32
    release = library.columba_stamp_job_release
    release.argtypes = [ctypes.c_uint64]
    release.restype = ctypes.c_int32
    job = start(workblock, len(workblock), target.to_bytes(32, "big"), 32)
    if not job:
        raise RuntimeError("Native stamper refused the fractional target")
    try:
        output = ctypes.create_string_buffer(32)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = poll(job, output)
            if status == 32:
                return output.raw
            if status != 0:
                raise RuntimeError(f"Native stamp job failed: {status}")
            time.sleep(0.001)
        raise TimeoutError("Native stamp generation timed out")
    finally:
        release(job)


def receiver_comparison(library_path, cost, insufficient=False):
    import RNS
    import RNS.Stamps as stamps
    import LXMF
    from RNS.vendor import umsgpack

    with tempfile.TemporaryDirectory(prefix="stamp-receiver-") as directory:
        root = Path(directory)
        config = root / "rns"
        config.mkdir()
        (config / "config").write_text(
            "[reticulum]\nshare_instance = no\n[logging]\nloglevel = 0\n[interfaces]\n"
        )
        output_streams = sys.stdout, sys.stderr
        RNS.Reticulum(str(config), loglevel=RNS.LOG_NONE)
        router = None
        try:
            router = LXMF.LXMRouter(storagepath=str(root / "lxmf"), enforce_stamps=True)
            destination = router.register_delivery_identity(RNS.Identity(), stamp_cost=cost)
            identity = RNS.Identity()
            source = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            RNS.Identity.remember(bytes(32), source.hash, identity.get_public_key(), None)
            message = LXMF.LXMessage(destination, source, "fractional stamp comparison", "reference")
            message.pack()
            workblock = stamps.stamp_workblock(message.message_id)
            target = stamps.target_from_cost(cost)
            deliveries = []
            router.register_delivery_callback(deliveries.append)

            if insufficient:
                # Find an integer-cost proof that does not satisfy the fraction.
                base = hashlib.sha256(workblock)
                for counter in range(100000):
                    candidate = counter.to_bytes(32, "big")
                    digest = base.copy()
                    digest.update(candidate)
                    if target < int.from_bytes(digest.digest(), "big") <= stamps.target_from_cost(8):
                        proofs = [("floored", candidate)]
                        break
                else:
                    raise RuntimeError("Could not construct the insufficient-proof control")
            else:
                library = ctypes.CDLL(library_path)
                native = native_stamp(library, workblock, target)
                # RNS itself generates the reference; no external LXMF hook is installed.
                reference, _ = stamps.generate_stamp(message.message_id, cost)
                proofs = [("native", native), ("python", reference)]

            results = []
            for name, proof in proofs:
                wire = (message.destination_hash + message.source_hash + message.signature
                        + umsgpack.packb(message.payload + [proof]))
                # Both solutions have the same message ID. Bypass only duplicate
                # suppression; signature and stamp enforcement remain enabled.
                accepted = router.lxmf_delivery(wire, method=LXMF.LXMessage.OPPORTUNISTIC, allow_duplicate=True)
                received = deliveries.pop() if deliveries else None
                results.append({
                    "generator": name,
                    "proof_size": len(proof),
                    "value": stamps.stamp_value(workblock, proof),
                    "rns_valid": stamps.stamp_valid(proof, cost, workblock),
                    "integer_valid": stamps.stamp_valid(proof, 8, workblock),
                    "receiver_accepted": accepted,
                    "delivered": None if received is None else {
                        "signature_valid": received.signature_validated,
                        "stamp_checked": received.stamp_checked,
                        "stamp_valid": received.stamp_valid,
                        "content": received.content_as_string(),
                        "same_proof": received.stamp == proof,
                    },
                })
            return {"cost": cost, "results": results}
        finally:
            try:
                if router is not None:
                    router.exit_handler()
                RNS.Reticulum.exit_handler()
            finally:
                # Reticulum shutdown redirects both streams to /dev/null.
                sys.stdout, sys.stderr = output_streams


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS CommonCrypto and Swift")
class NativeStampReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="native-stamp-reference-")
        cls.addClassCleanup(directory.cleanup)
        cls.library = Path(directory.name) / "libStampReference.dylib"
        source = os.environ.get("COLUMBA_NATIVE_STAMP_SOURCE", ROOT / "Sources/SwiftBLEBridge/StampGenerator.swift")
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-O", "-emit-library",
            "-target", f"{platform.machine()}-apple-macosx14.0",
            str(source), "-o", str(cls.library),
        ], check=True, capture_output=True, text=True, timeout=90)

    def compare(self, cost, insufficient=False):
        result = subprocess.run([
            sys.executable, "-B", str(Path(__file__).resolve()), "--receiver",
            str(self.library), str(cost), str(int(insufficient)),
        ], capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        print(json.dumps(report, sort_keys=True))
        return report["results"]

    def test_native_and_python_fractional_proofs_are_accepted_by_real_receiver(self):
        for cost in (8 + 1 / 256, 8.5, 8 + 255 / 256):
            with self.subTest(cost=cost):
                results = self.compare(cost)
                self.assertEqual([r["generator"] for r in results], ["native", "python"])
                for result in results:
                    self.assertEqual(result["proof_size"], 32)
                    self.assertTrue(result["rns_valid"], result)
                    self.assertTrue(result["receiver_accepted"], result)
                    self.assertEqual(result["delivered"], {
                        "signature_valid": True, "stamp_checked": True,
                        "stamp_valid": True, "content": "fractional stamp comparison",
                        "same_proof": True,
                    })

    def test_real_receiver_rejects_proof_valid_only_at_floored_integer_cost(self):
        result, = self.compare(8.5, insufficient=True)
        self.assertTrue(result["integer_valid"], result)
        self.assertFalse(result["rns_valid"], result)
        self.assertFalse(result["receiver_accepted"], result)
        self.assertIsNone(result["delivered"], result)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--receiver":
        print(json.dumps(receiver_comparison(sys.argv[2], float(sys.argv[3]), bool(int(sys.argv[4])))))
    else:
        unittest.main()
