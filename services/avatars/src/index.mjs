import catalog from '../catalog.json';
import bodies from '../bodies.json';
import { respond } from './service.mjs';

export default {
  fetch(request, env) { return respond(request, env, catalog, Date.now(), bodies); },
};
