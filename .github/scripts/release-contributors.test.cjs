const assert = require("node:assert/strict");
const { test } = require("node:test");
const { generateNotes } = require("./release-contributors.cjs");

const context = {
  env: { GITHUB_TOKEN: "test-token", GITHUB_REPOSITORY: "owner/repo" },
  lastRelease: { gitTag: "1.2.0" },
  nextRelease: { gitTag: "1.3.0", gitHead: "tested-commit" },
};

test("credits new and returning PR authors without duplicating the changelog", async (t) => {
  t.mock.method(globalThis, "fetch", async (url, options) => {
    assert.equal(url, "https://api.github.com/repos/owner/repo/releases/generate-notes");
    assert.equal(options.method, "POST");
    assert.equal(options.headers.Authorization, "Bearer test-token");
    assert.deepEqual(JSON.parse(options.body), {
      tag_name: "1.3.0",
      target_commitish: "tested-commit",
      previous_tag_name: "1.2.0",
    });
    return Response.json({ body: [
      "## What's Changed",
      "* fix: mention @unrelated by @returning in https://github.com/owner/repo/pull/1",
      "* feat: feature by @new-author in https://github.com/owner/repo/pull/2",
      "* fix: another by @returning in https://github.com/owner/repo/pull/3",
      "",
      "## New Contributors",
      "* @new-author made their first contribution in https://github.com/owner/repo/pull/2",
      "",
      "**Full Changelog**: https://github.com/owner/repo/compare/1.2.0...1.3.0",
    ].join("\n") });
  });
  assert.equal(await generateNotes({}, context), [
    "## New Contributors",
    "* @new-author made their first contribution in https://github.com/owner/repo/pull/2",
    "",
    "## Contributors",
    "Thanks to @returning, @new-author!",
  ].join("\n"));
});

test("credits returning contributors when there are no new contributors", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({
    body: "## What's Changed\n* fix: bug by @returning in https://github.com/owner/repo/pull/1\n",
  }));
  assert.equal(await generateNotes({}, context), "## Contributors\nThanks to @returning!");
});

test("omits empty sections when GitHub finds no PR contributors", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({
    body: "**Full Changelog**: https://github.com/owner/repo/compare/1.2.0...1.3.0",
  }));
  assert.equal(await generateNotes({}, context), "");
});

test("supports a first release without a previous tag and GH_TOKEN", async (t) => {
  t.mock.method(globalThis, "fetch", async (_, options) => {
    assert.equal(options.headers.Authorization, "Bearer gh-token");
    assert.equal(Object.hasOwn(JSON.parse(options.body), "previous_tag_name"), false);
    return Response.json({ body: "" });
  });
  await generateNotes({}, {
    ...context,
    env: { ...context.env, GH_TOKEN: "gh-token" },
    lastRelease: {},
  });
});

test("fails before publishing when GitHub rejects note generation", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response("Forbidden", { status: 403 }));
  await assert.rejects(generateNotes({}, context), /HTTP 403/);
});

test("rejects a malformed response instead of silently dropping contributors", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({}));
  await assert.rejects(generateNotes({}, context), /without a body/);
});

test("requires credentials and the repository before making a request", async (t) => {
  const fetchMock = t.mock.method(globalThis, "fetch");
  for (const env of [{}, { GITHUB_TOKEN: "test-token" }, { GITHUB_REPOSITORY: "owner/repo" }]) {
    await assert.rejects(generateNotes({}, { ...context, env }), /require GITHUB_TOKEN/);
  }
  assert.equal(fetchMock.mock.callCount(), 0);
});

test("excludes the maintainer from both sections while retaining other authors", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({ body: [
    "## What's Changed",
    "* fix: bug by @Maintainer in https://github.com/owner/repo/pull/1",
    "* fix: mention @maintainer by @returning in https://github.com/owner/repo/pull/2",
    "* feat: feature by @new-author in https://github.com/owner/repo/pull/3",
    "",
    "## New Contributors",
    "* @Maintainer made their first contribution in https://github.com/owner/repo/pull/1",
    "* @new-author made their first contribution in https://github.com/owner/repo/pull/3",
  ].join("\n") }));
  assert.equal(await generateNotes({ exclude: ["maintainer"] }, context), [
    "## New Contributors",
    "* @new-author made their first contribution in https://github.com/owner/repo/pull/3",
    "",
    "## Contributors",
    "Thanks to @returning, @new-author!",
  ].join("\n"));
});

test("omits both sections when only the excluded maintainer contributed", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({ body: [
    "## What's Changed",
    "* fix: bug by @maintainer in https://github.com/owner/repo/pull/1",
    "",
    "## New Contributors",
    "* @maintainer made their first contribution in https://github.com/owner/repo/pull/1",
    "",
    "**Full Changelog**: https://github.com/owner/repo/compare/1.2.0...1.3.0",
  ].join("\n") }));
  assert.equal(await generateNotes({ exclude: ["maintainer"] }, context), "");
});
