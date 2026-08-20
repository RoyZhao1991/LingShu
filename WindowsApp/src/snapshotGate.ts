/** Prevent a snapshot request started before a mutation from overwriting the mutation result. */
export class SnapshotGate {
  private mutationVersion = 0;

  beginRead(): number {
    return this.mutationVersion;
  }

  acceptsRead(version: number): boolean {
    return version === this.mutationVersion;
  }

  commitMutation(): void {
    this.mutationVersion += 1;
  }
}
