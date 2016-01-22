'use strict';

const chai = require('chai');
chai.use(require('sinon-chai'));

const _ = require('lodash');

_.extend(global, {
  _: _,
  expect: chai.expect,
  sinon: require('sinon'),
  fs: require('fs'),
  path: require('path'),
});
