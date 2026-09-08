enum Config {
    static let localeID = "en-US"

    // How long the Google Meet "Record this meeting?" offer stays on screen and actionable.
    // The countdown ring, the panel auto-dismiss, and the pending-offer expiry all read this,
    // so they can never drift apart.
    static let meetOfferSeconds = 15.0
}
