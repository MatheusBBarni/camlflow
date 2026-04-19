const { collectPiMonoPreflight } = require("./pi-mono-harness");

async function main() {
  const checkCamlFlowBuild = process.argv.includes("--check-camlflow-build");
  const report = await collectPiMonoPreflight({ checkCamlFlowBuild });
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = report.ok ? 0 : 1;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
