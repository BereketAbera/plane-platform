# Credentials come from the environment and never from a file here: CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET, CNTB_OAUTH2_USER
# and CNTB_OAUTH2_PASS for Contabo, and VERCEL_API_TOKEN for Vercel, with VERCEL_TEAM if the domain sits under a team.
provider "contabo" {}

provider "vercel" {}
