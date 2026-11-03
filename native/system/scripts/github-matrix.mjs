#!/usr/bin/env node
/**
 * Derive the GitHub Actions matrices from the checked-in package matrix
 * (`packages/<name>/prebuilds.json`). Single source: adding a platform
 * package extends CI and Release without editing a workflow.
 *
 *   node scripts/github-matrix.mjs ci                → one leg per distinct natively built platform
 *   node scripts/github-matrix.mjs cross             → one leg per cross-built platform package
 *   node scripts/github-matrix.mjs release-prebuild  → one leg per platform package
 */

import path from 'node:path';
import { platformDirs, readJson, root } from './repo.mjs';

/**
 * GitHub builder per prebuilds.json `platform` value. Native builders run the
 * payload they build; `cross` names the toolchain a Linux runner cross-builds
 * with when no hosted runner can execute the platform's binaries.
 */
const BUILDERS = {
  'linux-x64': { runner: 'ubuntu-24.04' },
  'linux-arm64': { runner: 'ubuntu-24.04-arm' },
  'darwin-x64': { runner: 'macos-15-intel' },
  'darwin-arm64': { runner: 'macos-latest' },
  // The public OpenHarmony SDK ships its NDK for x64 Linux hosts.
  'openharmony-arm64': { runner: 'ubuntu-24.04', cross: 'openharmony' },
};

function builderFor(platform) {
  const builder = BUILDERS[platform];
  if (!builder) {
    throw new Error(`missing GitHub runner for platform: ${platform}`);
  }
  return builder;
}

function platformManifests() {
  return platformDirs().map((dir) => ({
    dir,
    name: path.basename(dir),
    prebuilds: readJson(path.join(root, dir, 'prebuilds.json')),
  }));
}

function ciMatrix() {
  const platforms = [...new Set(platformManifests().map(({ prebuilds }) => prebuilds.platform))]
    .filter((platform) => builderFor(platform).cross === undefined)
    .sort();
  return {
    include: platforms.map((platform) => ({ platform, runner: builderFor(platform).runner })),
  };
}

function crossMatrix() {
  return {
    include: platformManifests()
      .filter(({ prebuilds }) => builderFor(prebuilds.platform).cross !== undefined)
      .map(({ dir, prebuilds }) => {
        const { runner, cross } = builderFor(prebuilds.platform);
        return { platform: prebuilds.platform, dir, runner, cross };
      }),
  };
}

function releasePrebuildMatrix() {
  return {
    include: platformManifests().map(({ dir, name, prebuilds }) => {
      const { runner, cross = '' } = builderFor(prebuilds.platform);
      return {
        platform: prebuilds.platform,
        package: name,
        dir,
        runner,
        cross,
        artifact: `prebuild-${name}`,
      };
    }),
  };
}

const target = process.argv[2];
const matrices = {
  ci: ciMatrix,
  cross: crossMatrix,
  'release-prebuild': releasePrebuildMatrix,
  compatibility: () => ciMatrix().include.flatMap((row) => [20, 22, 24, 26].map((node) => ({ ...row, node }))),
};

if (!target || !matrices[target]) {
  console.error(`Usage: node scripts/github-matrix.mjs <${Object.keys(matrices).join('|')}>`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(matrices[target]()));
