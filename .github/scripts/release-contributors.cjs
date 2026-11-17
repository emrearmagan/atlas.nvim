exports.generateNotes = async ({ exclude = [] }, { env, lastRelease, nextRelease }) => {
  const token = env.GH_TOKEN || env.GITHUB_TOKEN;
  const repository = env.GITHUB_REPOSITORY;
  if (!token || !repository) {
    throw new Error("Contributor notes require GITHUB_TOKEN (or GH_TOKEN) and GITHUB_REPOSITORY");
  }

  const response = await fetch(
    `${env.GITHUB_API_URL || "https://api.github.com"}/repos/${repository}/releases/generate-notes`,
    {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({
        tag_name: nextRelease.gitTag,
        target_commitish: nextRelease.gitHead,
        ...(lastRelease.gitTag && { previous_tag_name: lastRelease.gitTag }),
      }),
      signal: AbortSignal.timeout(30_000),
    },
  );
  if (!response.ok) {
    throw new Error(`GitHub contributor note generation failed (HTTP ${response.status})`);
  }
  const { body } = await response.json();
  if (typeof body !== "string") {
    throw new Error("GitHub returned release notes without a body");
  }

  // Keep semantic-release's changelog; only append GitHub's contributor credit.
  const excluded = new Set(exclude.map((login) => login.toLowerCase()));
  const contributors = new Set();
  const creditedNotes = body.split(/\r?\n/).filter((line) => {
    const author = line.match(
      /(?: by |^\* )(@[a-z\d-]+(?:\[bot\])?) (?:in|made their first contribution in) https?:\/\/\S+\/pull\/\d+\s*$/i,
    )?.[1];
    if (author && excluded.has(author.slice(1).toLowerCase())) return false;
    if (author) contributors.add(author);
    return true;
  }).join("\n");
  const newContributors = creditedNotes.match(
    /^## New Contributors\n([\s\S]*?)(?=^## |^\*\*Full Changelog\*\*:|(?![\s\S]))/m,
  )?.[1].trim();

  return [
    newContributors && `## New Contributors\n${newContributors}`,
    contributors.size && `## Contributors\nThanks to ${[...contributors].join(", ")}!`,
  ].filter(Boolean).join("\n\n");
};
