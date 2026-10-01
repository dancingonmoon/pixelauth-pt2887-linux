project('fp-tod-pixelauth', 'c',
  version: '0.1.0',
  meson_version: '>= 0.56',
  default_options: ['warning_level=2', 'c_std=gnu11'],
)

# 注意：不要加 version 约束。noble 上这个 pc 报的版本是 "1.94.7+tod1+tod1"，
# 写 '>= 1.95.1' 会直接构建失败（官方示例驱动就有这个坑）。
libfprint_tod_dep = dependency('libfprint-2-tod-1')

tod_driversdir = libfprint_tod_dep.get_variable(pkgconfig: 'tod_driversdir')
message('TOD 驱动安装目录: ' + tod_driversdir)

# shared_module 产出 libpixelauth_pt2887.so
# —— TOD 加载器要求文件名以 "lib" 开头、".so" 结尾（不能带 .1 之类后缀）
shared_module('pixelauth_pt2887',
  sources: ['pixelauth_pt2887.c'],
  dependencies: libfprint_tod_dep,
  install: true,
  install_dir: tod_driversdir,
)
