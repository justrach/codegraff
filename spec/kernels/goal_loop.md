# Kernel: goal / completion

Source of truth: `lean-proofs/Graff/GoalLoop.lean`.

Process kernel, not a cube and not a Turing machine: finite `Event` / `step`,
no tape, no halt state. The 360-cell cube is the snapshot of that machine.
GoalLoop is the worked example. Standing has no retire edge. Harness-done
is unreachable without a `write allCompleted`. World-done is not an event.

The diagram is the root-seat projection of the live Python `step`
(same function `check_properties` walks). Emit it with
`python3 spec/conformance.py --diagram goal_loop`. `--export` rewrites
the fence below from that function; do not hand-edit the arrows.

```mermaid
stateDiagram-v2
  [*] --> Idle
  Complete --> Idle: clear
  Complete --> Task: setGoal
  Complete --> TaskDone: setGoal
  Complete --> TaskOpen: setGoal
  Complete --> StandDone: setGoal standing
  Complete --> StandOpen: setGoal standing
  Complete --> Standing: setGoal standing
  Idle --> Task: setGoal
  Idle --> TaskDone: setGoal
  Idle --> TaskOpen: setGoal
  Idle --> StandDone: setGoal standing
  Idle --> StandOpen: setGoal standing
  Idle --> Standing: setGoal standing
  Paused --> Idle: clear
  Paused --> Task: resume
  Paused --> TaskArmed: resume
  Paused --> TaskDone: resume
  Paused --> TaskOpen: resume
  StandArmed --> StandOpen: attempt
  StandArmed --> Standing: attempt
  StandArmed --> Idle: clear
  StandArmed --> StandPaused: pause
  StandArmed --> StandDone: write done
  StandArmed --> StandOpen: write open
  StandDone --> Idle: clear
  StandDone --> StandPaused: pause
  StandDone --> StandOpen: write open
  StandOpen --> StandArmed: attempt / refuse_open
  StandOpen --> Idle: clear
  StandOpen --> StandPaused: pause
  StandOpen --> StandDone: write done
  StandPaused --> Idle: clear
  StandPaused --> StandArmed: resume
  StandPaused --> StandDone: resume
  StandPaused --> StandOpen: resume
  StandPaused --> Standing: resume
  Standing --> StandArmed: attempt / refuse_no_plan
  Standing --> Idle: clear
  Standing --> StandPaused: pause
  Standing --> StandDone: write done
  Standing --> StandOpen: write open
  Task --> TaskArmed: attempt / refuse_no_plan
  Task --> Idle: clear
  Task --> Paused: pause
  Task --> TaskDone: write done
  Task --> TaskOpen: write open
  TaskArmed --> Complete: attempt
  TaskArmed --> Idle: clear
  TaskArmed --> Paused: pause
  TaskArmed --> TaskDone: write done
  TaskArmed --> TaskOpen: write open
  TaskDone --> Complete: attempt
  TaskDone --> Idle: clear
  TaskDone --> Paused: pause
  TaskDone --> TaskOpen: write open
  TaskOpen --> TaskArmed: attempt / refuse_open
  TaskOpen --> Idle: clear
  TaskOpen --> Paused: pause
  TaskOpen --> TaskDone: write done
```
