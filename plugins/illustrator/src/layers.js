// Utilities for extracting layer metadata from the active Illustrator document.
// AI layers are simpler than PS: no "kind", but layers can contain sub-layers.

/**
 * @typedef {{ id: number, name: string, visible: boolean, locked: boolean, children: LayerNode[] }} LayerNode
 */

/**
 * Recursively convert an AI Layers collection into a plain array.
 * In Illustrator, `layer.layers` contains sub-layers (not page items).
 * @param {object} layers - doc.layers or layer.layers
 * @returns {LayerNode[]}
 */
export function buildLayerTree(layers) {
  const nodes = [];
  for (const layer of layers) {
    /** @type {LayerNode} */
    const node = {
      id: layer.id ?? 0,
      name: layer.name,
      visible: layer.visible,
      locked: layer.locked,
      children: [],
    };
    if (layer.layers?.length > 0) {
      node.children = buildLayerTree(layer.layers);
    }
    nodes.push(node);
  }
  return nodes;
}

/**
 * Count all layers recursively.
 * @param {object} layers
 * @returns {number}
 */
export function countLayers(layers) {
  let n = 0;
  for (const layer of layers) {
    n++;
    if (layer.layers?.length > 0) n += countLayers(layer.layers);
  }
  return n;
}

/**
 * Extract artboard names and count from the active document.
 * @param {object} doc - app.activeDocument
 * @returns {{ count: number, names: string[] }}
 */
export function getArtboards(doc) {
  try {
    const boards = doc.artboards;
    const names = [];
    for (const board of boards) {
      names.push(board.name);
    }
    return { count: names.length, names };
  } catch (_) {
    return { count: 0, names: [] };
  }
}
