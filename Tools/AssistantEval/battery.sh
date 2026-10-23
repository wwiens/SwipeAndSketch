#!/bin/zsh
# A fixed set of requests for comparing instruction and tool changes. Pass extra flags (e.g. --full).
cd "${0:A:h}"
B=./.build/release/AssistantEval
run() { local scenario=$1; shift; $B "$@" --verbose --scenario $scenario 2>&1 | grep -E "▶|·|↳|⟵|✗" | cut -c1-220; }
run empty $@ "Make a plate 80 by 50 mm and 5 mm thick with an M3 hole 6 mm in from each corner"
run empty $@ "Create a cylinder 30 mm in diameter and 40 mm tall"
run box $@ "Add a round boss 12 mm across and 8 mm tall in the middle of the top"
run box $@ "Put a 10 mm diameter hole all the way through the middle"
run box $@ "Cut a 20 by 10 mm pocket 5 mm deep into the top face, centered at x = -15"
run box $@ "Hollow it out with 2 mm walls, open at the top"
run box $@ "Chamfer the top edges 1 mm"
run box $@ "Make it 35 mm tall"
run box $@ "Move it up 10 mm and make a copy 70 mm to the right"
run two $@ "Which body is taller, and by how much?"
