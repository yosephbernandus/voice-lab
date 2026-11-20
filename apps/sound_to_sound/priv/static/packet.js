export const HEADER_BYTES = 12;
export const SAMPLES_PER_PACKET = 160;
export const PACKET_BYTES = HEADER_BYTES + SAMPLES_PER_PACKET;

export function writeHeader(view, sequenceNumber, timestamp, ssrc) {
  view.setUint8(0, 0x80);
  view.setUint8(1, 0);
  view.setUint16(2, sequenceNumber);
  view.setUint32(4, timestamp);
  view.setUint32(8, ssrc);
}

export function parse(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength !== PACKET_BYTES) return null;
  const view = new DataView(buffer);
  if (view.getUint8(0) !== 0x80 || view.getUint8(1) !== 0) return null;
  return {
    buffer,
    sequenceNumber: view.getUint16(2),
    timestamp: view.getUint32(4),
    ssrc: view.getUint32(8),
    payload: new Uint8Array(buffer, HEADER_BYTES, SAMPLES_PER_PACKET),
  };
}

export const packet = parse;
