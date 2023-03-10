# frozen_string_literal: true

Pod::Spec.new do |s|
  s.name = 'SelectPerConfigWithoutSharedDeps'
  s.version = '1.0.0.LOCAL'

  s.authors = %w[Square]
  s.homepage = 'https://github.com/Square/cocoapods-generate'
  s.source = { git: 'https://github.com/Square/cocoapods-generate' }
  s.summary = 'Testing pod'

  s.swift_versions = %w[5.2]
  s.ios.deployment_target = '9.0'

  s.source_files = 'Sources/**/*.{h,m,swift}'
  s.private_header_files = 'Sources/Internal/**/*.h'

  s.dependency 'D', configurations: ['Release']
  s.dependency 'OnlyPre', configurations: ['Debug']

  s.test_spec 'Tests' do |ts|
    ts.source_files = 'Tests/**/*.{m,swift}'
  end

  s.app_spec 'App' do |as|
    as.source_files = 'App/**/*.swift'
  end
end
