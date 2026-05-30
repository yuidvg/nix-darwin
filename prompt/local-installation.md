何かのツールを入れるときは、基本的に nix home manager で全て管理してください。
nixpkgsにない場合は、githubとかでflakeが直接提供されているものを利用するのが良いと思います。例えば、kimi-code/claude-code-flake など。
共有・恒常的なツールは nix-darwin リポジトリ (yuidvg/nix-darwin, `/private/etc/nix-darwin`) の `modules/base.nix` に、個人専用のツール・secret は同リポジトリの `personal.nix` に入れてください。(plural-reality の 2層構成は廃止し、単一リポジトリに統合済み)
破壊的なインストールがある場合は、それを削除した上で Nix に変えてしまって問題ないです。
