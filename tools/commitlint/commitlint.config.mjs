export default {
  extends: ['@commitlint/config-conventional'],
  defaultIgnores: false,
  rules: {
    'header-max-length': [2, 'always', 50],
  },
};
