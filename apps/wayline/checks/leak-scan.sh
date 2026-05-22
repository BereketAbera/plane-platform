#!/usr/bin/env bash
# Copyright (c) 2026 Bereket Abera
# SPDX-License-Identifier: AGPL-3.0-only
#
# Scans build output for the upstream brand: Plane, plane.so, planes.so, makeplane, planepowers, hostnames
# under plane. (plane.github.com, for example), and the lower-case word in prose (space before it, space or
# sentence punctuation after, so object keys and emoji tags stay out). It also rejects a mailto: followed by
# something that is not an address, which is what a text rewrite leaves behind when it hits a link.
# Exits non-zero on any match that no entry in leak-allowlist.txt covers. Entries are Perl regexes tested
# against the match wrapped in << >>, plus 50 characters each side, so an entry must name the match itself
# and a real leak next to an allowed one is still caught. Every entry must state its reason.
#
# Scope: what the frontends ship, and the mail templates in backend/templates, which are all the backend
# context now copies over upstream's. Everything else in the backend image, and its Python, is covered
# by backend/check_image.py inside the built image.
#
#   apps/wayline/checks/leak-scan.sh [web] [admin] [space] [backend]     default: all four
# shellcheck source=../scripts/lib.sh
source "$(dirname "$0")/../scripts/lib.sh"

[[ $# -gt 0 ]] || set -- web admin space backend
dirs=()
for target in "$@"; do
  case "$target" in
    web) dirs+=("$SRC/apps/web/build/client") ;;
    admin) dirs+=("$SRC/apps/admin/build/client") ;;
    space) dirs+=("$SRC/apps/space/build/client" "$SRC/apps/space/build/server") ;;
    backend) dirs+=("$WAYLINE/backend/templates") ;;
    *) die "unknown scan target: $target" ;;
  esac
done
for d in "${dirs[@]}"; do [[ -d "$d" ]] || die "nothing to scan at $d, build it first"; done

find "${dirs[@]}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.css' -o -name '*.html' \
  -o -name '*.txt' -o -name '*.json' -o -name '*.webmanifest' -o -name '*.svg' -o -name '*.xml' -o -name '*.map' \) -print0 \
  | perl -e '
use strict; use warnings;
my ($allow_file, $root) = @ARGV; @ARGV = ();
my @allow;
open(my $af, "<", $allow_file) or die "cannot read $allow_file: $!";
while (my $line = <$af>) {
  chomp $line;
  next if $line =~ /^\s*(#|$)/;
  my ($re, $reason) = split /\s+## /, $line, 2;
  die "allowlist entry has no reason: $line\n" unless defined $reason && $reason =~ /\S/;
  push @allow, { re => qr/$re/, text => $re, hits => 0 };
}
close $af;
my ($files, $matches, $allowed, %bad) = (0, 0, 0);
my @paths = do { local $/ = "\0"; my @p = <STDIN>; chomp @p; @p };
for my $path (@paths) {
  $files++;
  open(my $fh, "<:raw", $path) or die "cannot read $path: $!";
  my $data = do { local $/; <$fh> };
  close $fh;
  while ($data =~ /(Plane|planes?\.so|makeplane|planepowers|(?<= )plane(?=[ ,.!?])|(?<![A-Za-z0-9_\$-])plane\.(?:[a-z][a-z0-9-]*\.)*(?:com|so|sh|town|io|dev|org|net)\b|mailto:[A-Za-z][A-Za-z ]*(?=["\x27`]))/g) {
    $matches++;
    my $start = $-[0] - 50; $start = 0 if $start < 0;
    my $ctx = substr($data, $start, $-[0] - $start) . "<<$1>>" . substr($data, $+[0], 50);
    $ctx =~ s/\s+/ /g;
    my $hit = 0;
    for my $a (@allow) { if ($ctx =~ $a->{re}) { $a->{hits}++; $hit = 1; last; } }
    if ($hit) { $allowed++; next; }
    (my $rel = $path) =~ s/^\Q$root\E\/?//;
    push @{ $bad{$rel} }, $ctx;
  }
}
my $leaks = 0;
for my $rel (sort keys %bad) {
  my @c = @{ $bad{$rel} };
  $leaks += @c;
  print "LEAK $rel (" . scalar(@c) . ")\n";
  my $n = 0;
  for my $ctx (@c) { print "    ...$ctx...\n"; last if ++$n >= 5; }
}
print "leak-scan: $files files, $matches matches, $allowed allowlisted, $leaks leaks\n";
for my $a (@allow) { print "  allowlisted $a->{hits}x: $a->{text}\n" if $a->{hits}; }
exit($leaks ? 1 : 0);
' "$WAYLINE/checks/leak-allowlist.txt" "$SRC"
