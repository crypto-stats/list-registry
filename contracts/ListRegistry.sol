//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "./Ownable.sol";

error InvalidValue();
error ElementNotFound();

contract ListRegistry is Ownable {
  struct List {
    bytes16 first;
    bytes16 last;
  }

  struct Element {
    bytes16 previous;
    bytes16 next;
    string value;
  }

  mapping(bytes32 => List) private lists;
  mapping(bytes32 => mapping(bytes16 => Element)) private listData;

  event ElementAdded(bytes32 indexed list, bytes16 index, string value);
  event ElementRemoved(bytes32 indexed list, bytes16 index, string value);

  function getList(bytes32 list) external view returns (bytes16 first, bytes16 last) {
    List memory _list = lists[list];
    return (_list.first, _list.last);
  }

  function getElement(bytes32 list, bytes16 index) external view returns (
    string memory value,
    bytes16 previous,
    bytes16 next
  ) {
    Element memory _element = listData[list][index];

    if (bytes(_element.value).length == 0) {
      revert ElementNotFound();
    }

    return (_element.value, _element.previous, _element.next);
  }

  function getFullList(bytes32 list) external view returns (string[] memory listValues) {
    uint256 length = 0;

    bytes16 first = lists[list].first;
    bytes16 next = first;
    if (next == 0) {
      return new string[](0);
    }

    while (true) {
      next = listData[list][next].next;
      length += 1;

      if (next == 0) {
        break;
      }
    }

    listValues = new string[](length);

    next = first;

    for (uint256 i = 0; i < listValues.length; i += 1) {
      listValues[i] = listData[list][next].value;
      next = listData[list][next].next;
    }
  }

  function addElement(bytes32 list, string calldata value) external onlyOwner returns (bytes16 index) {
    if (bytes(value).length == 0) {
      revert InvalidValue();
    }

    List memory _list = lists[list];

    index = psuedoRandomID(value);

    if (_list.first == 0) {
      lists[list] = List(index, index);
    } else {
      listData[list][_list.last].next = index;
      lists[list] = List(_list.first, index);
    }

    listData[list][index] = Element(_list.last, 0, value);

    emit ElementAdded(list, index, value);
  }

  function removeElement(bytes32 list, bytes16 index) external onlyOwner {
    List memory _list = lists[list];

    Element memory _element = listData[list][index];
    if (bytes(_element.value).length == 0) {
      revert ElementNotFound();
    }

    listData[list][index] = Element(0, 0, '');

    if (_list.first == index) {
      lists[list].first = _element.next;
    } else {
      listData[list][_element.previous].next = _element.next;
    }

    if (_list.last == index) {
      lists[list].last = _element.previous;
    } else {
      listData[list][_element.next].previous = _element.previous;
    }

    emit ElementRemoved(list, index, _element.value);
  }

  function psuedoRandomID(string memory value) private view returns (bytes16) {
    return bytes16(keccak256(abi.encodePacked(block.difficulty, block.timestamp, value)));        
  }
}
