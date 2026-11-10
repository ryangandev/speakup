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
# A "done" after a pause, then more speech within 1.2 s: the take goes on.
clip done-then-more  recording none "That covers the main trade offs. [[slnc 1000]] done [[slnc 700]] actually, one more thing about the cost."
clip done-then-more2 recording none "So that was my approach. [[slnc 1000]] done [[slnc 1000]] well, almost. The rollout took two more weeks."
clip done-actually   recording none "So those were the trade offs. [[slnc 1000]] done [[slnc 300]] actually, wait."
clip done-late-more  recording none "That is my answer. [[slnc 1000]] done [[slnc 900]] and one more thing to add."
# A name that sounds like "done", after a pause: it is not "done".
clip don-name        recording none "The person who approved it was my manager. [[slnc 900]] Don. [[slnc 1400]] He ran the team for years."
# A long silence is not a command.
clip silence-only    recording none "That was the whole story so far. [[slnc 9000]] and then it continued."

# Between takes, a short utterance that is exactly a command.
clip again           betweenTakes again         "again"
clip next-question   betweenTakes next          "next question"
clip say-that-again  betweenTakes repeatThat    "say that again"
clip better-version  betweenTakes betterVersion "read the better version"
clip stop            betweenTakes stop          "stop"
# The nervousness rating: one short word, alone.
clip rating-three    betweenTakes rating3       "three"
clip rating-two      betweenTakes rating2       "two"
clip rating-five     betweenTakes rating5       "five"
clip rating-one      betweenTakes rating1       "one"
clip skip            betweenTakes skip          "skip"
clip weather         betweenTakes unrecognized  "what is the weather going to be like today"
# A command word that starts a longer utterance, after a short pause, is not a command.
clip again-nowait    betweenTakes unrecognized  "again [[slnc 400]] no wait, never mind"
clip stop-sentence   betweenTakes unrecognized  "stop [[slnc 500]] at the next exit please"

print "Wrote $(wc -l < "$manifest" | tr -d ' ') clips to $out"
