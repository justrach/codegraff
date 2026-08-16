import Graff.ToolCatalog
import Graff.Transport
import Graff.Provider
import Graff.GoalLoop
import Graff.PathConfine
import Graff.Shape
import Graff.Score
import Graff.BashPolicy

open Graff

/-- Lean prints the cube sizes. These are not Python counts: they are
`List.length` of the enumerations the theorems pin (`catalog_cube`,
`one_ws_cell`, …). -/
def main : IO Unit := do
  IO.println "lean-proofs numbers (from the definitions, not from Python)"
  IO.println s!"catalog      {ToolCatalog.catalogCells}"
  IO.println s!"transport    {Transport.transportCells}  ws={Transport.wsCells}"
  IO.println s!"provider     {Provider.providerRows}  responses={Provider.responsesCount}"
  IO.println s!"goal         {GoalLoop.goalCells}  refuse_open={GoalLoop.refuseOpenCells}  refuse_no_plan={GoalLoop.refuseNoPlanCells}"
  IO.println s!"lease        {PathConfine.leaseCells}  warns={PathConfine.warnCells}"
  IO.println s!"shape        {Shape.shapeCells}  R0={Shape.r0Cells}  R3={Shape.r3Cells}"
  IO.println s!"score        {Score.scoreCells}  filed={Score.filedCells}  titles={Score.titleCells}  classes={Score.classCells}"
  IO.println s!"bash         {BashPolicy.bashCells}  allowed={BashPolicy.allowedCells}  external={BashPolicy.externalCells}"
  IO.println s!"cells_total  {ToolCatalog.catalogCells + Transport.transportCells + Provider.providerRows + GoalLoop.goalCells + PathConfine.leaseCells + Shape.shapeCells + Score.scoreCells + BashPolicy.bashCells}"
