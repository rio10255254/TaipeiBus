import copy
import hashlib
import unittest
from datetime import datetime, timedelta

from signing import validate_profile


class AppStoreProfileTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 2)
        self.profile = {
            "UUID": "12345678-1234-1234-1234-123456789ABC",
            "TeamIdentifier": ["TESTTEAM01"],
            "ExpirationDate": self.now + timedelta(days=365),
            "Entitlements": {"application-identifier": "TESTTEAM01.com.test.Bus", "get-task-allow": False},
            "DeveloperCertificates": [b"test-certificate"],
        }

    def validate(self, profile=None):
        return validate_profile(profile or self.profile, "TESTTEAM01", "com.test.Bus", self.now)

    def test_store_profile_provides_exact_identity_and_uuid(self):
        uuid, identity = self.validate()
        self.assertEqual(uuid, self.profile["UUID"])
        self.assertEqual(identity, hashlib.sha1(b"test-certificate").hexdigest().upper())

    def test_different_team_is_rejected(self):
        self.profile["TeamIdentifier"] = ["OTHERTEAM1"]
        with self.assertRaisesRegex(ValueError, "different Apple team"):
            self.validate()

    def test_other_app_is_rejected(self):
        self.profile["Entitlements"]["application-identifier"] = "TESTTEAM01.com.other.Bus"
        with self.assertRaisesRegex(ValueError, "Bundle ID"):
            self.validate()

    def test_development_ad_hoc_and_enterprise_profiles_are_rejected(self):
        for field, value in (("get-task-allow", True), ("ProvisionedDevices", []), ("ProvisionsAllDevices", True)):
            profile = copy.deepcopy(self.profile)
            if field == "get-task-allow":
                profile["Entitlements"][field] = value
            else:
                profile[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "distribution profile"):
                self.validate(profile)

    def test_expired_or_missing_expiration_is_rejected(self):
        for expiration in (self.now - timedelta(days=1), self.now + timedelta(days=7), None):
            profile = copy.deepcopy(self.profile)
            if expiration is None:
                del profile["ExpirationDate"]
            else:
                profile["ExpirationDate"] = expiration
            with self.subTest(expiration=expiration), self.assertRaisesRegex(ValueError, "expires"):
                self.validate(profile)

    def test_untrusted_uuid_cannot_be_used_as_a_file_path(self):
        self.profile["UUID"] = "../../outside"
        with self.assertRaisesRegex(ValueError, "UUID"):
            self.validate()

    def test_multiple_or_missing_signing_certificates_are_rejected(self):
        for certificates in ([], [b"one", b"two"], ["not-der-bytes"]):
            self.profile["DeveloperCertificates"] = certificates
            with self.subTest(certificates=certificates), self.assertRaisesRegex(ValueError, "one distribution certificate"):
                self.validate()


if __name__ == "__main__":
    unittest.main()
