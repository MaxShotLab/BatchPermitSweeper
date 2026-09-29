"""Offline tests for deployment configuration and unsigned owner transactions."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from validate_config import load_config, validate
from owner_batch import build_batch


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "chainId": 31337,
            "owner": "0x" + "11" * 20,
            "recipient": "0x" + "22" * 20,
            "workers": ["0x" + "33" * 20, "0x" + "44" * 20],
            "requireSafeOwner": True,
        }

    def test_valid_config(self):
        self.assertEqual(validate(self.config), self.config)

    def test_single_worker_is_an_array(self):
        self.config["workers"] = self.config["workers"][:1]
        validate(self.config)
        self.config["workers"] = self.config["workers"][0]
        with self.assertRaises(ValueError):
            validate(self.config)

    def test_reject_zero_and_invalid_addresses(self):
        for value in ("0x" + "00" * 20, "0x123", 123, None):
            config = copy.deepcopy(self.config)
            config["owner"] = value
            with self.assertRaises(ValueError):
                validate(config)

    def test_reject_invalid_chain_ids(self):
        for value in (0, -1, True, "8453", 2**256):
            self.config["chainId"] = value
            with self.assertRaises(ValueError):
                validate(self.config)

    def test_reject_duplicate_workers(self):
        self.config["workers"].append(self.config["workers"][0])
        with self.assertRaises(ValueError):
            validate(self.config)

    def test_separate_owner_and_workers(self):
        self.config["workers"] = [self.config["owner"]]
        with self.assertRaises(ValueError):
            validate(self.config)

    def test_reject_extra_secret_fields(self):
        self.config["privateKey"] = "must-never-be-in-config"
        with self.assertRaises(ValueError):
            validate(self.config)

    def test_reject_string_boolean(self):
        self.config["requireSafeOwner"] = "true"
        with self.assertRaises(ValueError):
            validate(self.config)

    def test_reject_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            text = json.dumps(self.config).replace('"chainId": 31337', '"chainId": 1, "chainId": 31337')
            path.write_text(text)
            with self.assertRaises(ValueError):
                load_config(path)

    @patch("owner_batch.calldata", return_value="0x12345678")
    def test_batch_does_not_implicitly_unpause(self, encode):
        batch = build_batch(self.config, "0x" + "55" * 20, ["0x" + "66" * 20], False)
        self.assertEqual(len(batch["transactions"]), 1)
        self.assertEqual(batch["chainId"], "31337")
        encode.assert_called_once_with("setTokenAllowed(address,bool)", "0x" + "66" * 20, "true")

    @patch("owner_batch.calldata", return_value="0x12345678")
    def test_batch_can_explicitly_unpause(self, encode):
        batch = build_batch(self.config, "0x" + "55" * 20, [], True)
        self.assertEqual(batch["transactions"][0]["value"], "0")
        encode.assert_called_once_with("unpause()")

    def test_empty_batch_rejected(self):
        with self.assertRaises(ValueError):
            build_batch(self.config, "0x" + "55" * 20, [], False)


if __name__ == "__main__":
    unittest.main()
