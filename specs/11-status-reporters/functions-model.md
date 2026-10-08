# Functions
- report: input = role, Docker socket path, token file, issue number, repository; output = one issue body edit; failure leaves the previous body.
- read status: input = issue number, now; output = validated payload or failure, never raw body text in error messages.
