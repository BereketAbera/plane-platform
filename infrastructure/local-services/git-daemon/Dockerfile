# Read-only git:// server. Alpine packages the daemon separately from git itself.
FROM mirror.gcr.io/library/alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
RUN apk add --no-cache git-daemon=~2 && git config --system --add safe.directory '*'
USER 65534:65534
EXPOSE 9418
ENTRYPOINT ["git", "daemon", "--verbose", "--export-all", "--reuseaddr", "--base-path=/srv/git", "--informative-errors"]
CMD ["/srv/git"]
