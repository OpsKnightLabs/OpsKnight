import { complianceControls } from './controls';

/** Source pointers only; not attestations that a workflow or operating control succeeded. */
export const complianceEvidence = complianceControls.map(control => ({
  controlId: control.id,
  paths: control.evidence,
}));

export function evidenceSourceUrl(path: string): string {
  return `https://github.com/OpsKnightLabs/OpsKnight/blob/main/${path.split('/').map(encodeURIComponent).join('/')}`;
}
