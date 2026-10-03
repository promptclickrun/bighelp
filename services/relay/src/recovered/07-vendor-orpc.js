// ../../node_modules/.pnpm/@orpc+shared@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/shared/dist/index.mjs
function resolveMaybeOptionalOptions(rest) {
  return rest[0] ?? {};
}
__name(resolveMaybeOptionalOptions, "resolveMaybeOptionalOptions");
var ORPC_SHARED_PACKAGE_NAME = "@orpc/shared";
var ORPC_SHARED_PACKAGE_VERSION = "1.15.0";
function sequential(fn) {
  let lastOperationPromise = Promise.resolve();
  return (...args) => {
    return lastOperationPromise = lastOperationPromise.catch(() => {
    }).then(() => {
      return fn(...args);
    });
  };
}
__name(sequential, "sequential");
var GLOBAL_OTEL_CONFIG_KEY = `__${ORPC_SHARED_PACKAGE_NAME}@${ORPC_SHARED_PACKAGE_VERSION}/otel/config__`;
function isAsyncIteratorObject(maybe) {
  if (!maybe || typeof maybe !== "object") {
    return false;
  }
  return "next" in maybe && typeof maybe.next === "function" && Symbol.asyncIterator in maybe && typeof maybe[Symbol.asyncIterator] === "function";
}
__name(isAsyncIteratorObject, "isAsyncIteratorObject");
var fallbackAsyncDisposeSymbol = /* @__PURE__ */ Symbol.for("asyncDispose");
var asyncDisposeSymbol = Symbol.asyncDispose ?? fallbackAsyncDisposeSymbol;
var AsyncIteratorClass = class {
  static {
    __name(this, "AsyncIteratorClass");
  }
  #isDone = false;
  #isExecuteComplete = false;
  #cleanup;
  #next;
  constructor(next, cleanup) {
    this.#cleanup = cleanup;
    this.#next = sequential(async () => {
      if (this.#isDone) {
        return { done: true, value: void 0 };
      }
      try {
        const result = await next();
        if (result.done) {
          this.#isDone = true;
        }
        return result;
      } catch (err) {
        this.#isDone = true;
        throw err;
      } finally {
        if (this.#isDone && !this.#isExecuteComplete) {
          this.#isExecuteComplete = true;
          await this.#cleanup("next");
        }
      }
    });
  }
  next() {
    return this.#next();
  }
  async return(value) {
    this.#isDone = true;
    if (!this.#isExecuteComplete) {
      this.#isExecuteComplete = true;
      await this.#cleanup("return");
    }
    return { done: true, value };
  }
  async throw(err) {
    this.#isDone = true;
    if (!this.#isExecuteComplete) {
      this.#isExecuteComplete = true;
      await this.#cleanup("throw");
    }
    throw err;
  }
  /**
   * asyncDispose symbol only available in esnext, we should fallback to Symbol.for('asyncDispose')
   */
  async [asyncDisposeSymbol]() {
    this.#isDone = true;
    if (!this.#isExecuteComplete) {
      this.#isExecuteComplete = true;
      await this.#cleanup("dispose");
    }
  }
  [Symbol.asyncIterator]() {
    return this;
  }
};
function getConstructor(value) {
  if (!isTypescriptObject(value)) {
    return null;
  }
  return Object.getPrototypeOf(value)?.constructor;
}
__name(getConstructor, "getConstructor");
function isTypescriptObject(value) {
  return !!value && (typeof value === "object" || typeof value === "function");
}
__name(isTypescriptObject, "isTypescriptObject");

// ../../node_modules/.pnpm/@orpc+client@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/client/dist/shared/client.CZlviB0y.mjs
var ORPC_CLIENT_PACKAGE_NAME = "@orpc/client";
var ORPC_CLIENT_PACKAGE_VERSION = "1.15.0";
var COMMON_ORPC_ERROR_DEFS = {
  BAD_REQUEST: {
    status: 400,
    message: "Bad Request"
  },
  UNAUTHORIZED: {
    status: 401,
    message: "Unauthorized"
  },
  FORBIDDEN: {
    status: 403,
    message: "Forbidden"
  },
  NOT_FOUND: {
    status: 404,
    message: "Not Found"
  },
  METHOD_NOT_SUPPORTED: {
    status: 405,
    message: "Method Not Supported"
  },
  NOT_ACCEPTABLE: {
    status: 406,
    message: "Not Acceptable"
  },
  TIMEOUT: {
    status: 408,
    message: "Request Timeout"
  },
  CONFLICT: {
    status: 409,
    message: "Conflict"
  },
  PRECONDITION_FAILED: {
    status: 412,
    message: "Precondition Failed"
  },
  PAYLOAD_TOO_LARGE: {
    status: 413,
    message: "Payload Too Large"
  },
  UNSUPPORTED_MEDIA_TYPE: {
    status: 415,
    message: "Unsupported Media Type"
  },
  UNPROCESSABLE_CONTENT: {
    status: 422,
    message: "Unprocessable Content"
  },
  TOO_MANY_REQUESTS: {
    status: 429,
    message: "Too Many Requests"
  },
  CLIENT_CLOSED_REQUEST: {
    status: 499,
    message: "Client Closed Request"
  },
  INTERNAL_SERVER_ERROR: {
    status: 500,
    message: "Internal Server Error"
  },
  NOT_IMPLEMENTED: {
    status: 501,
    message: "Not Implemented"
  },
  BAD_GATEWAY: {
    status: 502,
    message: "Bad Gateway"
  },
  SERVICE_UNAVAILABLE: {
    status: 503,
    message: "Service Unavailable"
  },
  GATEWAY_TIMEOUT: {
    status: 504,
    message: "Gateway Timeout"
  }
};
function fallbackORPCErrorStatus(code, status) {
  return status ?? COMMON_ORPC_ERROR_DEFS[code]?.status ?? 500;
}
__name(fallbackORPCErrorStatus, "fallbackORPCErrorStatus");
function fallbackORPCErrorMessage(code, message) {
  return message || COMMON_ORPC_ERROR_DEFS[code]?.message || code;
}
__name(fallbackORPCErrorMessage, "fallbackORPCErrorMessage");
var globalORPCErrorConstructors;
var ORPCError = class _ORPCError extends Error {
  static {
    __name(this, "ORPCError");
  }
  defined;
  code;
  status;
  data;
  static {
    const GLOBAL_ORPC_ERROR_CONSTRUCTORS_SYMBOL = /* @__PURE__ */ Symbol.for(`__${ORPC_CLIENT_PACKAGE_NAME}@${ORPC_CLIENT_PACKAGE_VERSION}/error/ORPC_ERROR_CONSTRUCTORS__`);
    void (globalThis[GLOBAL_ORPC_ERROR_CONSTRUCTORS_SYMBOL] ??= /* @__PURE__ */ new WeakSet());
    globalORPCErrorConstructors = globalThis[GLOBAL_ORPC_ERROR_CONSTRUCTORS_SYMBOL];
    globalORPCErrorConstructors.add(_ORPCError);
  }
  constructor(code, ...rest) {
    const options = resolveMaybeOptionalOptions(rest);
    if (options.status !== void 0 && !isORPCErrorStatus(options.status)) {
      throw new Error("[ORPCError] Invalid error status code.");
    }
    const message = fallbackORPCErrorMessage(code, options.message);
    super(message, options);
    this.code = code;
    this.status = fallbackORPCErrorStatus(code, options.status);
    this.defined = options.defined ?? false;
    this.data = options.data;
  }
  toJSON() {
    return {
      defined: this.defined,
      code: this.code,
      status: this.status,
      message: this.message,
      data: this.data
    };
  }
  /**
   * Workaround for Next.js where different contexts use separate
   * dependency graphs, causing multiple ORPCError constructors existing and breaking
   * `instanceof` checks across contexts.
   *
   * This is particularly problematic with "Optimized SSR", where orpc-client
   * executes in one context but is invoked from another. When an error is thrown
   * in the execution context, `instanceof ORPCError` checks fail in the
   * invocation context due to separate class constructors.
   *
   * @todo Remove this and related code if Next.js resolves the multiple dependency graph issue.
   */
  static [Symbol.hasInstance](instance) {
    if (globalORPCErrorConstructors.has(this)) {
      const constructor = getConstructor(instance);
      if (constructor && globalORPCErrorConstructors.has(constructor)) {
        return true;
      }
    }
    return super[Symbol.hasInstance](instance);
  }
};
function isORPCErrorStatus(status) {
  return status < 200 || status >= 400;
}
__name(isORPCErrorStatus, "isORPCErrorStatus");

// ../../node_modules/.pnpm/@orpc+standard-server@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/standard-server/dist/index.mjs
var EventEncoderError = class extends TypeError {
  static {
    __name(this, "EventEncoderError");
  }
};
var EventDecoderError = class extends TypeError {
  static {
    __name(this, "EventDecoderError");
  }
};
var LINE_ENDING_REGEX$1 = /\r\n|\r(?!\n)|\n/;
var MESSAGE_DELIMITER_REGEX = /(?:\r\n|\r(?!\n)|\n){2}/;
var MESSAGE_DELIMITER_GLOBAL_REGEX = /(?:\r\n|\r(?!\n)|\n){2}/g;
var CR = 13;
var LF = 10;
var SPACE = 32;
function decodeEventMessage(encoded) {
  const message = {
    data: void 0,
    event: void 0,
    id: void 0,
    retry: void 0,
    comments: []
  };
  for (const line of encoded.split(LINE_ENDING_REGEX$1)) {
    if (line === "") {
      continue;
    }
    const index = line.indexOf(":");
    const value = index === -1 ? "" : line.slice(line.charCodeAt(index + 1) === SPACE ? index + 2 : index + 1);
    if (index === 0) {
      message.comments.push(value);
      continue;
    }
    switch (index === -1 ? line : line.slice(0, index)) {
      case "data":
        message.data = message.data === void 0 ? value : `${message.data}
${value}`;
        break;
      case "event":
        message.event = value;
        break;
      case "id":
        message.id = value;
        break;
      case "retry": {
        const maybeInteger = Number.parseInt(value, 10);
        if (maybeInteger >= 0 && maybeInteger.toString() === value) {
          message.retry = maybeInteger;
        }
        break;
      }
    }
  }
  return message;
}
__name(decodeEventMessage, "decodeEventMessage");
var EventDecoder = class {
  static {
    __name(this, "EventDecoder");
  }
  constructor(options = {}) {
    this.options = options;
  }
  pending = [];
  // Last up-to-3 characters of the pending buffer, prefixed to the next chunk
  // so a delimiter straddling the boundary is still found.
  tail = "";
  // Set when a chunk-ending '\r' was already consumed as a line ending, so a
  // leading '\n' in the next chunk is the second half of that CRLF pair.
  discardLeadingLF = false;
  feed(chunk) {
    if (chunk === "") {
      return;
    }
    if (this.discardLeadingLF) {
      this.discardLeadingLF = false;
      if (chunk.charCodeAt(0) === LF) {
        chunk = chunk.slice(1);
        if (chunk === "") {
          return;
        }
      }
    }
    const scan = this.tail + chunk;
    if (!MESSAGE_DELIMITER_REGEX.test(scan)) {
      this.pending.push(chunk);
      this.tail = scan.slice(-3);
      return;
    }
    this.pending.push(chunk);
    const buffered = this.pending.length === 1 ? chunk : this.pending.join("");
    const offset = buffered.length - scan.length;
    const parts = [];
    let start = 0;
    for (const match of scan.matchAll(MESSAGE_DELIMITER_GLOBAL_REGEX)) {
      parts.push(buffered.slice(start, offset + match.index));
      start = offset + match.index + match[0].length;
    }
    const incomplete = buffered.slice(start);
    this.pending.length = 0;
    this.tail = incomplete.slice(-3);
    if (incomplete === "") {
      this.discardLeadingLF = chunk.charCodeAt(chunk.length - 1) === CR;
    } else {
      this.pending.push(incomplete);
    }
    for (const encoded of parts) {
      const message = decodeEventMessage(encoded);
      if (this.options.onEvent) {
        this.options.onEvent(message);
      }
    }
  }
  end() {
    if (this.pending.length !== 0) {
      throw new EventDecoderError("Event Iterator ended before complete");
    }
  }
};
var EventDecoderStream = class extends TransformStream {
  static {
    __name(this, "EventDecoderStream");
  }
  constructor() {
    let decoder;
    super({
      start(controller) {
        decoder = new EventDecoder({
          onEvent: /* @__PURE__ */ __name((event) => {
            controller.enqueue(event);
          }, "onEvent")
        });
      },
      transform(chunk) {
        decoder.feed(chunk);
      },
      flush() {
        decoder.end();
      }
    });
  }
};
var LINE_ENDING_REGEX = /\r\n|[\n\r]/;
function containsLineBreak(value) {
  return LINE_ENDING_REGEX.test(value);
}
__name(containsLineBreak, "containsLineBreak");
function assertEventId(id) {
  if (containsLineBreak(id)) {
    throw new EventEncoderError("Event's id must not contain a carriage return or newline character");
  }
}
__name(assertEventId, "assertEventId");
function assertEventRetry(retry) {
  if (!Number.isInteger(retry) || retry < 0) {
    throw new EventEncoderError("Event's retry must be a integer and >= 0");
  }
}
__name(assertEventRetry, "assertEventRetry");
function assertEventComment(comment) {
  if (containsLineBreak(comment)) {
    throw new EventEncoderError("Event's comment must not contain a carriage return or newline character");
  }
}
__name(assertEventComment, "assertEventComment");
var EVENT_SOURCE_META_SYMBOL = /* @__PURE__ */ Symbol("ORPC_EVENT_SOURCE_META");
function withEventMeta(container, meta3) {
  if (meta3.id === void 0 && meta3.retry === void 0 && !meta3.comments?.length) {
    return container;
  }
  if (meta3.id !== void 0) {
    assertEventId(meta3.id);
  }
  if (meta3.retry !== void 0) {
    assertEventRetry(meta3.retry);
  }
  if (meta3.comments !== void 0) {
    for (const comment of meta3.comments) {
      assertEventComment(comment);
    }
  }
  return new Proxy(container, {
    get(target, prop, receiver) {
      if (prop === EVENT_SOURCE_META_SYMBOL) {
        return meta3;
      }
      return Reflect.get(target, prop, receiver);
    }
  });
}
__name(withEventMeta, "withEventMeta");
function getEventMeta(container) {
  return isTypescriptObject(container) ? Reflect.get(container, EVENT_SOURCE_META_SYMBOL) : void 0;
}
__name(getEventMeta, "getEventMeta");

// ../../node_modules/.pnpm/@orpc+client@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/client/dist/shared/client.BLtwTQUg.mjs
function mapEventIterator(iterator, maps) {
  const mapError = /* @__PURE__ */ __name(async (error51) => {
    let mappedError = await maps.error(error51);
    if (mappedError !== error51) {
      const meta3 = getEventMeta(error51);
      if (meta3 && isTypescriptObject(mappedError)) {
        mappedError = withEventMeta(mappedError, meta3);
      }
    }
    return mappedError;
  }, "mapError");
  return new AsyncIteratorClass(async () => {
    const { done, value } = await (async () => {
      try {
        return await iterator.next();
      } catch (error51) {
        throw await mapError(error51);
      }
    })();
    let mappedValue = await maps.value(value, done);
    if (mappedValue !== value) {
      const meta3 = getEventMeta(value);
      if (meta3 && isTypescriptObject(mappedValue)) {
        mappedValue = withEventMeta(mappedValue, meta3);
      }
    }
    return { done, value: mappedValue };
  }, async () => {
    try {
      await iterator.return?.();
    } catch (error51) {
      throw await mapError(error51);
    }
  });
}
__name(mapEventIterator, "mapEventIterator");

// ../../node_modules/.pnpm/@orpc+contract@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/contract/dist/shared/contract.D_dZrO__.mjs
var ValidationError = class extends Error {
  static {
    __name(this, "ValidationError");
  }
  issues;
  data;
  constructor(options) {
    super(options.message, options);
    this.issues = options.issues;
    this.data = options.data;
  }
};
function mergeErrorMap(errorMap1, errorMap2) {
  return { ...errorMap1, ...errorMap2 };
}
__name(mergeErrorMap, "mergeErrorMap");
var ContractProcedure = class {
  static {
    __name(this, "ContractProcedure");
  }
  /**
   * This property holds the defined options for the contract procedure.
   */
  "~orpc";
  constructor(def) {
    if (def.route?.successStatus && isORPCErrorStatus(def.route.successStatus)) {
      throw new Error("[ContractProcedure] Invalid successStatus.");
    }
    if (Object.values(def.errorMap).some((val) => val && val.status && !isORPCErrorStatus(val.status))) {
      throw new Error("[ContractProcedure] Invalid error status code.");
    }
    this["~orpc"] = def;
  }
};
function isContractProcedure(item) {
  if (item instanceof ContractProcedure) {
    return true;
  }
  return (typeof item === "object" || typeof item === "function") && item !== null && "~orpc" in item && typeof item["~orpc"] === "object" && item["~orpc"] !== null && "errorMap" in item["~orpc"] && "route" in item["~orpc"] && "meta" in item["~orpc"];
}
__name(isContractProcedure, "isContractProcedure");

// ../../node_modules/.pnpm/@orpc+contract@1.15.0_@opentelemetry+api@1.9.0/node_modules/@orpc/contract/dist/index.mjs
function mergeMeta(meta1, meta22) {
  return { ...meta1, ...meta22 };
}
__name(mergeMeta, "mergeMeta");
function mergeRoute(a, b) {
  return { ...a, ...b };
}
__name(mergeRoute, "mergeRoute");
function prefixRoute(route, prefix) {
  if (!route.path) {
    return route;
  }
  return {
    ...route,
    path: `${prefix}${route.path}`
  };
}
__name(prefixRoute, "prefixRoute");
function unshiftTagRoute(route, tags) {
  return {
    ...route,
    tags: [...tags, ...route.tags ?? []]
  };
}
__name(unshiftTagRoute, "unshiftTagRoute");
function mergePrefix(a, b) {
  return a ? `${a}${b}` : b;
}
__name(mergePrefix, "mergePrefix");
function mergeTags(a, b) {
  return a ? [...a, ...b] : b;
}
__name(mergeTags, "mergeTags");
function enhanceRoute(route, options) {
  let router = route;
  if (options.prefix) {
    router = prefixRoute(router, options.prefix);
  }
  if (options.tags?.length) {
    router = unshiftTagRoute(router, options.tags);
  }
  return router;
}
__name(enhanceRoute, "enhanceRoute");
function enhanceContractRouter(router, options) {
  if (isContractProcedure(router)) {
    const enhanced2 = new ContractProcedure({
      ...router["~orpc"],
      errorMap: mergeErrorMap(options.errorMap, router["~orpc"].errorMap),
      route: enhanceRoute(router["~orpc"].route, options)
    });
    return enhanced2;
  }
  if (typeof router !== "object" || router === null) {
    return router;
  }
  const enhanced = {};
  for (const key in router) {
    enhanced[key] = enhanceContractRouter(router[key], options);
  }
  return enhanced;
}
__name(enhanceContractRouter, "enhanceContractRouter");
var ContractBuilder = class _ContractBuilder extends ContractProcedure {
  static {
    __name(this, "ContractBuilder");
  }
  constructor(def) {
    super(def);
    this["~orpc"].prefix = def.prefix;
    this["~orpc"].tags = def.tags;
  }
  /**
   * Sets or overrides the initial meta.
   *
   * @see {@link https://orpc.dev/docs/metadata Metadata Docs}
   */
  $meta(initialMeta) {
    return new _ContractBuilder({
      ...this["~orpc"],
      meta: initialMeta
    });
  }
  /**
   * Sets or overrides the initial route.
   * This option is typically relevant when integrating with OpenAPI.
   *
   * @see {@link https://orpc.dev/docs/openapi/routing OpenAPI Routing Docs}
   * @see {@link https://orpc.dev/docs/openapi/input-output-structure OpenAPI Input/Output Structure Docs}
   */
  $route(initialRoute) {
    return new _ContractBuilder({
      ...this["~orpc"],
      route: initialRoute
    });
  }
  /**
   * Sets or overrides the initial input schema.
   *
   * @see {@link https://orpc.dev/docs/procedure#initial-configuration Initial Procedure Configuration Docs}
   */
  $input(initialInputSchema) {
    return new _ContractBuilder({
      ...this["~orpc"],
      inputSchema: initialInputSchema
    });
  }
  /**
   * Adds type-safe custom errors to the contract.
   * The provided errors are spared-merged with any existing errors in the contract.
   *
   * @see {@link https://orpc.dev/docs/error-handling#type%E2%80%90safe-error-handling Type-Safe Error Handling Docs}
   */
  errors(errors) {
    return new _ContractBuilder({
      ...this["~orpc"],
      errorMap: mergeErrorMap(this["~orpc"].errorMap, errors)
    });
  }
  /**
   * Sets or updates the metadata for the contract.
   * The provided metadata is spared-merged with any existing metadata in the contract.
   *
   * @see {@link https://orpc.dev/docs/metadata Metadata Docs}
   */
  meta(meta3) {
    return new _ContractBuilder({
      ...this["~orpc"],
      meta: mergeMeta(this["~orpc"].meta, meta3)
    });
  }
  /**
   * Sets or updates the route definition for the contract.
   * The provided route is spared-merged with any existing route in the contract.
   * This option is typically relevant when integrating with OpenAPI.
   *
   * @see {@link https://orpc.dev/docs/openapi/routing OpenAPI Routing Docs}
   * @see {@link https://orpc.dev/docs/openapi/input-output-structure OpenAPI Input/Output Structure Docs}
   */
  route(route) {
    return new _ContractBuilder({
      ...this["~orpc"],
      route: mergeRoute(this["~orpc"].route, route)
    });
  }
  /**
   * Defines the input validation schema for the contract.
   *
   * @see {@link https://orpc.dev/docs/procedure#input-output-validation Input Validation Docs}
   */
  input(schema) {
    return new _ContractBuilder({
      ...this["~orpc"],
      inputSchema: schema
    });
  }
  /**
   * Defines the output validation schema for the contract.
   *
   * @see {@link https://orpc.dev/docs/procedure#input-output-validation Output Validation Docs}
   */
  output(schema) {
    return new _ContractBuilder({
      ...this["~orpc"],
      outputSchema: schema
    });
  }
  /**
   * Prefixes all procedures in the contract router.
   * The provided prefix is post-appended to any existing router prefix.
   *
   * @note This option does not affect procedures that do not define a path in their route definition.
   *
   * @see {@link https://orpc.dev/docs/openapi/routing#route-prefixes OpenAPI Route Prefixes Docs}
   */
  prefix(prefix) {
    return new _ContractBuilder({
      ...this["~orpc"],
      prefix: mergePrefix(this["~orpc"].prefix, prefix)
    });
  }
  /**
   * Adds tags to all procedures in the contract router.
   * This helpful when you want to group procedures together in the OpenAPI specification.
   *
   * @see {@link https://orpc.dev/docs/openapi/openapi-specification#operation-metadata OpenAPI Operation Metadata Docs}
   */
  tag(...tags) {
    return new _ContractBuilder({
      ...this["~orpc"],
      tags: mergeTags(this["~orpc"].tags, tags)
    });
  }
  /**
   * Applies all of the previously defined options to the specified contract router.
   *
   * @see {@link https://orpc.dev/docs/router#extending-router Extending Router Docs}
   */
  router(router) {
    return enhanceContractRouter(router, this["~orpc"]);
  }
};
var oc = new ContractBuilder({
  errorMap: {},
  route: {},
  meta: {}
});
var EVENT_ITERATOR_DETAILS_SYMBOL = /* @__PURE__ */ Symbol("ORPC_EVENT_ITERATOR_DETAILS");
function eventIterator(yields, returns) {
  return {
    "~standard": {
      [EVENT_ITERATOR_DETAILS_SYMBOL]: { yields, returns },
      vendor: "orpc",
      version: 1,
      validate(iterator) {
        if (!isAsyncIteratorObject(iterator)) {
          return { issues: [{ message: "Expect event iterator", path: [] }] };
        }
        const mapped = mapEventIterator(iterator, {
          async value(value, done) {
            const schema = done ? returns : yields;
            if (!schema) {
              return value;
            }
            const result = await schema["~standard"].validate(value);
            if (result.issues) {
              throw new ORPCError("EVENT_ITERATOR_VALIDATION_FAILED", {
                message: "Event iterator validation failed",
                cause: new ValidationError({
                  issues: result.issues,
                  message: "Event iterator validation failed",
                  data: value
                })
              });
            }
            return result.value;
          },
          error: /* @__PURE__ */ __name(async (error51) => error51, "error")
        });
        return { value: mapped };
      }
    }
  };
}
__name(eventIterator, "eventIterator");

