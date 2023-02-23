// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMockOracle {
  function setAnswer(uint256 _price) external;
}
