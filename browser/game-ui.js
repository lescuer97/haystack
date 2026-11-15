// Emscripten JS library: cosmetic game startup notification.
mergeInto(LibraryManager.library, {
  haystack_ui_result__sig: "vi",
  haystack_ui_result: function (ok) {
    try {
      if (typeof Module !== "undefined" && typeof Module["onHaystackStartup"] === "function") {
        Module["onHaystackStartup"](ok ? "ready" : "error");
      }
    } catch (_) {
      // The startup layer is cosmetic; the game must not depend on it.
    }
  },
});
