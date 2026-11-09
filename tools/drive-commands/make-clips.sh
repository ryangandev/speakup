#!/bin/zsh
# Builds the spoken clips that drive-commands checks, and their manifest.
# Each clip is 16 kHz mono 16-bit speech from `say`; [[slnc N]] inserts N ms of silence.
# Manifest columns: name, listening mode, expected outcome.
#   done          the take ends, cut at the start of the last utterance ("done" or "I'm done")
#   none          nothing is a command
#   <command>     between takes: that command (again, next, repeatThat, betterVersion, stop)
#   unrecognized  between takes: speech that is not a command
set -euo pipefail
out="${0:A:h}/clips"
rm -rf "$out"
mkdir -p "$out"
manifest="$out/manifest.tsv"
: > "$manifest"

clip() {
  local name=$1 mode=$2 expect=$3 text=$4
  say -o "$out/$name.wav" --data-format=LEI16@16000 "$text"
  print -r -- "$name	$mode	$expect" >> "$manifest"
}

# While recording, "done" counts only after a pause and before 1.2 s of silence.
clip pause-done      recording done "That is the main point of my answer. [[slnc 1500]] done"
clip im-done         recording done "So that covers the trade offs. [[slnc 1200]] I'm done"
clip thinking-pause  recording done "We got it done. [[slnc 2000]] And then we shipped it to everyone. [[slnc 1500]] done"
clip long-pause      recording done "The first part was easy. [[slnc 8000]] The second part took longer. [[slnc 1200]] done"
clip midsentence     recording none "We finally got it done by Friday and the customers were happy about the result"
clip no-pause-done   recording none "Well, I think the main reason we chose that design was that it kept the team independent, so that is my answer. done"

# Between takes, a short utterance that is exactly a command.
clip again           betweenTakes again         "again"
clip next-question   betweenTakes next          "next question"
clip say-that-again  betweenTakes repeatThat    "say that again"
clip better-version  betweenTakes betterVersion "read the better version"
clip stop            betweenTakes stop          "stop"
clip weather         betweenTakes unrecognized  "what is the weather going to be like today"

print "Wrote $(wc -l < "$manifest" | tr -d ' ') clips to $out"
