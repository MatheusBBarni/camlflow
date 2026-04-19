use std::collections::BTreeMap;

use zed_extension_api::{self as zed, settings::LspSettings, LanguageServerId};

const LANGUAGE_SERVER_ID: &str = "camlflow-lsp";

struct CamlFlowExtension;

impl CamlFlowExtension {
    fn command_for_worktree(&self, worktree: &zed::Worktree) -> zed::Result<zed::Command> {
        let lsp_settings =
            LspSettings::for_worktree(LANGUAGE_SERVER_ID, worktree).unwrap_or_default();
        let binary_settings = lsp_settings.binary;

        let command = binary_settings
            .as_ref()
            .and_then(|settings| settings.path.clone())
            .or_else(|| worktree.which("camlflow"))
            .ok_or_else(|| {
                "could not find `camlflow` on PATH; install it or set `lsp.camlflow-lsp.binary.path` in Zed settings".to_string()
            })?;

        let args = binary_settings
            .as_ref()
            .and_then(|settings| settings.arguments.clone())
            .unwrap_or_else(|| vec!["lsp".to_string()]);

        let mut env: BTreeMap<String, String> = worktree.shell_env().into_iter().collect();
        if let Some(extra_env) = binary_settings.and_then(|settings| settings.env) {
            env.extend(extra_env);
        }

        Ok(zed::Command {
            command,
            args,
            env: env.into_iter().collect(),
        })
    }
}

impl zed::Extension for CamlFlowExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        match language_server_id.as_ref() {
            LANGUAGE_SERVER_ID => self.command_for_worktree(worktree),
            _ => Err(format!(
                "unrecognized language server for CamlFlow: {language_server_id}"
            )),
        }
    }
}

zed::register_extension!(CamlFlowExtension);
