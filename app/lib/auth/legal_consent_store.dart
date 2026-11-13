import '../net/models.dart';

const legalVersion = '3';
const locationLegalVersion = '3';

// Only authenticated server records establish document consent. The legacy
// device-wide legal.consent.v1 preference is deliberately never read or written.
bool hasPrivacyConsent(ConsentRecord? consent) =>
    consent?.privacy?.version == legalVersion;

bool hasLocationConsent(ConsentRecord? consent) =>
    consent?.location?.version == locationLegalVersion;
