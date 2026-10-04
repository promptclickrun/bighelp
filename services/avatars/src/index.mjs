import catalog from '../catalog.json';
import { respond } from './service.mjs';

export default {
  fetch(request, env) { return respond(request, env, catalog); },
};
