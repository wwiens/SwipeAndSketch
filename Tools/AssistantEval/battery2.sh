#!/bin/zsh
# A second, differently worded set, to check the first set's fixes generalize.
cd "${0:A:h}"
B=./.build/release/AssistantEval
run() { local scenario=$1; shift; $B "$@" --verbose --scenario $scenario 2>&1 | grep -E "▶|⟵|✗|parts" | cut -c1-240; }
run empty $@ "Make a 40 mm cube"
run box $@ "Round all the edges 2 mm"
run box $@ "Add four M4 counterbored holes near the corners, 8 mm in"
run two $@ "Delete the cylinder"
run two $@ "Hide Body 02"
run box $@ "Turn it 45 degrees"
run box $@ "Make a 3 mm deep circular recess 20 mm across in the top"
run box $@ "How much material does it use?"
run box $@ "Add a 5 mm fillet to the top edges and make it hollow with 1.5 mm walls open at the bottom"
run plate $@ "Extrude the circle 15 mm"
