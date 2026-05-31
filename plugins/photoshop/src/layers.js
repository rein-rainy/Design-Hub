// Utilities for extracting layer metadata from the active PS document.

/**
 * @typedef {{ id: number, name: string, kind: string, visible: boolean, children: LayerNode[] }} LayerNode
 */

const KIND_MAP = {
  1: 'pixel',
  2: 'adjustment',
  3: 'text',
  4: 'vector',
  5: 'smartObject',
  6: 'video',
  7: 'group',
  8: 'threeD',
  9: 'gradient',
  10: 'pattern',
  11: 'solidColor',
  13: 'background',
};

/**
 * Recursively convert a PS Layers collection into a plain array.
 * @param {object} layers - doc.layers or layer.layers
 * @returns {LayerNode[]}
 */
export function buildLayerTree(layers) {
  const nodes = [];
  for (const layer of layers) {
    /** @type {LayerNode} */
    const node = {
      id: layer.id,
      name: layer.name,
      kind: KIND_MAP[layer.kind] ?? String(layer.kind),
      visible: layer.visible,
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
 * Count all layers recursively (groups count as 1 + their children).
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
