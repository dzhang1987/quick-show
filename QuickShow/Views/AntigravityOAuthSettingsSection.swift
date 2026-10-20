// AntigravityOAuthSettingsSection: Google Antigravity OAuth 客户端凭据配置视图。
// 支持用户自建 Google Cloud OAuth Client ID / Secret，覆盖默认策略。

import SwiftUI

struct AntigravityOAuthSettingsSection: View {
    @State private var clientIdInput: String = AntigravityOAuthConfig.customClientId ?? ""
    @State private var clientSecretInput: String = AntigravityOAuthConfig.customClientSecret ?? ""
    @State private var isSaved: Bool = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("默认开箱即用。若企业或开发者需要接入自建的 Google Cloud OAuth 2.0 客户端凭据，可在下方配置覆盖：")
                    .font(.system(size: Theme.Typography.footnote))
                    .foregroundColor(.secondary)

                HStack {
                    Text("Client ID")
                        .font(.system(size: Theme.Typography.footnote, weight: .medium))
                        .frame(width: 90, alignment: .leading)
                    TextField("xxx.apps.googleusercontent.com", text: $clientIdInput)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Client Secret")
                        .font(.system(size: Theme.Typography.footnote, weight: .medium))
                        .frame(width: 90, alignment: .leading)
                    SecureField("输入 Client Secret", text: $clientSecretInput)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    if AntigravityOAuthConfig.hasCustomConfig {
                        Button("恢复默认") {
                            AntigravityOAuthConfig.clearCustomConfig()
                            clientIdInput = ""
                            clientSecretInput = ""
                            isSaved = true
                        }
                        .font(.system(size: Theme.Typography.footnote))
                    }
                    Spacer()
                    Button("保存配置") {
                        AntigravityOAuthConfig.saveCustomConfig(
                            clientId: clientIdInput,
                            clientSecret: clientSecretInput
                        )
                        isSaved = true
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: Theme.Typography.footnote))
                }
                .padding(.top, 2)

                if isSaved {
                    Text("OAuth 客户端配置已生效")
                        .font(.system(size: Theme.Typography.footnote))
                        .foregroundColor(Theme.Colors.statusGood)
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("OAuth 高级配置（自建客户端凭据）")
                Spacer()
                if AntigravityOAuthConfig.hasCustomConfig {
                    Text("已自定义")
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
