import assert from "node:assert/strict";
import test from "node:test";
import { SnapshotGate } from "../src/snapshotGate.ts";

test("rejects a poll result captured before a mutation snapshot", () => {
  const gate = new SnapshotGate();
  const stalePoll = gate.beginRead();
  gate.commitMutation();
  assert.equal(gate.acceptsRead(stalePoll), false);
  assert.equal(gate.acceptsRead(gate.beginRead()), true);
});
