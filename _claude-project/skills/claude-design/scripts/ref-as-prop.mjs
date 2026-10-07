/* Components written for React 19 receive `ref` as an ordinary prop. Design
 * pages and canvases run React 18, which strips it — so a Radix trigger rendered
 * through a component (`asChild`) loses its anchor and the overlay never opens.
 * REF_AS_PROP restores React 19's behaviour on 18, for this bundle only: a plain
 * function component is rendered through a cached forwardRef wrapper that hands
 * any ref back in as a prop. Used by the JSX runtime shim (the
 * bundle's own JSX) and by the footer (components the page mounts by name).
 *
 * A React Aria collection element (`Item`, `Section`) stays unwrapped: it carries a
 * static `getCollectionNode`, takes no ref, and `CollectionBuilder` rejects any type
 * that is not the function itself. */
export const REF_AS_PROP = `function refAsProp(R, cache, t) {
  var w = cache.get(t);
  if (!w) {
    w = R.forwardRef(function (props, ref) { return t(Object.assign({}, props, { ref: ref })); });
    w.displayName = t.displayName || t.name;
    cache.set(t, w);
  }
  return w;
}
function isPlainComponent(t) {
  return typeof t === 'function' && !(t.prototype && t.prototype.isReactComponent) && t.$$typeof === undefined
    && typeof t.getCollectionNode !== 'function';
}
function soleChild(R, props) {
  var c = props && props.children;
  if (Array.isArray(c) && c.length === 1) { c = c[0]; props = Object.assign({}, props, { children: c }); }
  // In the canvas editor every x-import sits in a display:contents host div, which
  // has no box: a trigger slotted onto it measures 0,0 and the overlay lands in the
  // corner. Give that host a box the size of what it wraps.
  if (props && props.asChild && R.isValidElement(c) && c.type === 'div' && /(^|\\s)sc-host-x(\\s|$)/.test(c.props.className || '')) {
    props = Object.assign({}, props, { children: R.cloneElement(c, { style: Object.assign({}, c.props.style, { display: 'inline-flex' }) }) });
  }
  return props;
}`
