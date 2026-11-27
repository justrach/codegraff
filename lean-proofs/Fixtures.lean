import Graff.PreviewGrace
import Graff.RemoteAnswer
import Graff.ScopeReminder
import Graff.SimulatorPasteboard

def main : List String → IO UInt32
  | ["preview-grace"] => IO.print Graff.PreviewGrace.table *> pure 0
  | ["remote-answer"] => IO.print Graff.RemoteAnswer.table *> pure 0
  | ["scope-reminder"] => IO.println Graff.ScopeReminder.boundaryFixture *> pure 0
  | ["simulator-pasteboard"] => IO.print Graff.SimulatorPasteboard.table *> pure 0
  | _ => IO.eprintln "Unknown Graff proof fixture" *> pure 1
