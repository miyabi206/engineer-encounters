Deno.test("Deno smoke test", () => {
  if (1 + 1 !== 2) {
    throw new Error("Expected 1 + 1 to equal 2");
  }
});
