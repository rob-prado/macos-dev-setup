#!/usr/bin/env bash

clean_rn_job() {
	rm -rf ~/.gradle/caches/* \
		~/.android/build-cache \
		~/Library/Developer/Xcode/DerivedData/* \
		~/Library/Caches/CocoaPods \
		"$TMPDIR"/metro-* \
		"$TMPDIR"/react-* 2>/dev/null || true
}

clean_install_caches_job() {
	rm -rf ~/Library/Caches/Homebrew/* \
		~/src/ruby-* \
		~/.cache/ruby-install/* \
		~/Library/Caches/org.xcodes.xcodes/* \
		~/Library/Application\ Support/xcodes/*.xip \
		/tmp/xcodes* 2>/dev/null || true
}

clean_profiles_job() {
	pf_rm_pat "ANDROID_HOME"
	pf_rm_pat "JAVA_HOME"
	pf_rm_pat "fnm"
	pf_rm_pat "chruby"
		_scrub_profile_file "$(get_target_rc)"
	_scrub_profile_file "$HOME/.profile"
}

clean_folders_job() {
	rm -rf ~/.nvm \
		~/.nodenv \
		~/.rubies \
		~/.fnm \
		~/.sdkman \
		~/.corepack \
		~/.cache/yarn \
		~/.yarn \
		/Applications/Xcode*.app 2>/dev/null || true
}

rn_cleanup() {
	run_bg "Deep Clean" "Caches" clean_rn_job || true
	run_bg "Installer Clean" "Homebrew/SDK" clean_install_caches_job || true
	command -v npm &>/dev/null && run_bg "NPM" "cache" npm cache clean -f || true
	command -v yarn &>/dev/null && run_bg "Yarn" "cache" yarn cache clean --all || true
	command -v watchman &>/dev/null && run_bg "Watchman" "del-all" watchman watch-del-all || true
	run_bg "Gem" "cleanup" run_in_ruby_env "gem cleanup -q &>/dev/null" || true
	command -v brew &>/dev/null && run_bg "Brew" "prune" brew cleanup --prune=all || true
}

# ==============================================================================
