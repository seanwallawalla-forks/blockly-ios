/*
* Copyright 2015 Google Inc. All Rights Reserved.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation

/**
Protocol for events that occur on a `Layout`.
*/
@objc(BKYLayoutDelegate)
public protocol LayoutDelegate {
  /**
  Event that is called when an entire layout's display needs to be updated from the UI side.

  - Parameter layout: The `Layout` that changed.
  */
  func layoutDisplayChanged(layout: Layout)

  /**
  Event that is called when a layout's needs to be repositioned from the UI side.

  - Parameter layout: The `Layout` that changed.
  */
  func layoutPositionChanged(layout: Layout)

  // TODO:(vicng) Add an event for when a layout is deleted
}

/**
Abstract base class that defines a node in a tree-hierarchy. It is used for storing layout
information on how to render and position itself relative to other nodes in this hierarchy. Nodes
can represent fields, blocks, or a workspace (which are always root nodes).

The coordinate system used inside a `Layout` object is in the "Workspace coordinate system".
There are many properties inside a `Layout` object that should not be accessed or
modified by UI views during rendering (eg. `relativePosition`, `size`, `absolutePosition`). Instead,
a UI view can simply access the property `viewFrame` to determine its "UIView coordinate system"
position and size.
*/
@objc(BKYLayout)
public class Layout: NSObject {
  // MARK: - Properties

  /// A unique identifier used to identify this layout for its lifetime
  public final let uuid: String
  /// The workspace node which this node belongs to.
  public final weak var workspaceLayout: WorkspaceLayout!
  /// The parent node of this layout. If this value is nil, this layout is the root node.
  public internal(set) final weak var parentLayout: Layout? {
    didSet {
      if parentLayout == oldValue {
        return
      }

      // Remove self from old parent's childLayouts
      oldValue?.childLayouts.remove(self)

      // Add self to new parent's childLayouts
      parentLayout?.childLayouts.insert(self)
    }
  }

  /// Layouts whose `parentLayout` is set to this layout
  public private(set) final var childLayouts = Set<Layout>()

  /// Position relative to `self.parentLayout`
  internal final var relativePosition: WorkspacePoint = WorkspacePointZero
  /// Content size of this layout
  internal final var contentSize: WorkspaceSize = WorkspaceSizeZero {
    didSet {
      updateTotalSize()
    }
  }
  /// Inline edge insets for the layout.
  internal final var edgeInsets: WorkspaceEdgeInsets = WorkspaceEdgeInsetsZero {
    didSet {
      updateTotalSize()
    }
  }

  // TODO(vicng): If ConnectionLayout is created, change absolutePosition to be final
  /// Absolute position relative to the root node.
  internal var absolutePosition: WorkspacePoint = WorkspacePointZero
  /// Total size used by this layout. This value is calculated by combining `edgeInsets` and
  /// `contentSize`.
  internal private(set) final var totalSize: WorkspaceSize = WorkspaceSizeZero

  /**
  UIView frame for this layout relative to its parent *view* node's layout. For example, the parent
  view node layout for a Field is a Block, while the parent view node for a Block is a Workspace.
  */
  public internal(set) final var viewFrame: CGRect = CGRectZero {
    didSet {
      if viewFrame != oldValue {
        self.needsRepositioning = true
      }
    }
  }

  /**
  Flag indicating if this layout's corresponding view needs to be completely re-drawn.
  Setting this value to true schedules a change event to be called on the `delegate` at the
  beginning of the next run loop.
  */
  public final var needsDisplay: Bool = false {
    didSet {
      if self.needsDisplay {
        LayoutEventManager.sharedInstance.scheduleChangeEventForLayout(self)
      }
    }
  }
  /**
  Flag indicating if this layout's corresponding view needs to be repositioned.
  Setting this value to true schedules a change event to be called on the `delegate` at the
  beginning of the next run loop.
  */
  public final var needsRepositioning: Bool = false {
    didSet {
      if self.needsRepositioning {
        LayoutEventManager.sharedInstance.scheduleChangeEventForLayout(self)
      }
    }
  }

  // TODO:(vicng) Consider making the LayoutView a property of the layout instead of using a
  // delegate.
  /// The delegate for events that occur on this instance
  public final weak var delegate: LayoutDelegate?

  // MARK: - Initializers

  public init(workspaceLayout: WorkspaceLayout!) {
    self.uuid = NSUUID().UUIDString
    self.workspaceLayout = workspaceLayout
    super.init()
  }

  // MARK: - Abstract

  /**
  This method repositions its children and recalculates its `contentSize` based on the positions
  of its children.

  - Parameter includeChildren: A flag indicating whether `performLayout(:)` should be called on any
  child layouts, prior to repositioning them. It is the responsibility of subclass implementations
  to honor this flag.
  - Note: This method needs to be implemented by a subclass of `Layout`.
  */
  public func performLayout(includeChildren includeChildren: Bool) {
    bky_assertionFailure("\(__FUNCTION__) needs to be implemented by a subclass")
  }

  // MARK: - Public

  /**
  For every `Layout` in its tree hierarchy (including itself), this method recalculates its
  `contentSize`, `relativePosition`, `absolutePosition`, and `viewFrame`, based on the current state
  of `self.parentLayout`.
  */
  public func updateLayoutDownTree() {
    performLayout(includeChildren: true)
    refreshViewPositionsForTree(
      parentAbsolutePosition: (parentLayout?.absolutePosition ?? WorkspacePointZero))
  }

  /**
  Performs the layout of its direct children (and not of its grandchildren) and repeats this for
  every parent up the tree. When the top is reached, the `absolutePosition` and `viewFrame` for
  each layout in the tree is re-calculated.
  */
  public final func updateLayoutUpTree() {
    // Re-position content at this level
    performLayout(includeChildren: false)

    if let parentLayout = self.parentLayout {
      // Recursively do the same thing up the tree hierarchy
      parentLayout.updateLayoutUpTree()
    } else {
      // The top of the tree has been reached. Re-calculate view positions for the entire tree.
      refreshViewPositionsForTree(parentAbsolutePosition: WorkspacePointZero)
    }
  }

  // MARK: - Internal

  /**
  For every `Layout` in its tree hierarchy (including itself), updates the `absolutePosition` and
  `viewFrame` based on the current state of this object.

  - Parameter parentAbsolutePosition: The absolute position of its parent layout.
  - Parameter includeFields: If true, recursively update view positions for field layouts. If false,
  skip them.
  - Note: `parentAbsolutePosition` is passed as a parameter here to eliminate direct references to
  `self.parentLayout` inside this method. This results in better performance.
  */
  internal final func refreshViewPositionsForTree(
    parentAbsolutePosition parentAbsolutePosition: WorkspacePoint,
    includeFields: Bool = true)
  {
    // TODO:(vicng) Optimize this method so it only recalculates view positions for layouts that
    // are "dirty"

    // Update absolute position
    self.absolutePosition = WorkspacePointMake(
      parentAbsolutePosition.x + relativePosition.x + edgeInsets.left,
      parentAbsolutePosition.y + relativePosition.y + edgeInsets.top)

    // Update the view frame (InputLayouts and BlockGroupLayouts do not need to update their view
    // frames as they do not get rendered)
    if !(self is InputLayout) && !(self is BlockGroupLayout) &&
      (includeFields || !(self is FieldLayout))
    {
      refreshViewFrame()
    }

    for layout in self.childLayouts {
      // Automatically skip if this is a field and we're not allowing them
      if includeFields || !(layout is FieldLayout) {
        layout.refreshViewPositionsForTree(
          parentAbsolutePosition: self.absolutePosition, includeFields: includeFields)
      }
    }
  }

  /**
  Refreshes `viewFrame` based on the current state of this object.
  */
  internal func refreshViewFrame() {
    // Update the view frame
    self.viewFrame =
      workspaceLayout.viewFrameFromWorkspacePoint(self.absolutePosition, size: self.contentSize)
  }

  /**
  If `needsDisplay` or `needsRepositioning` has been set for this layout, the appropriate change
  event is sent to the `delegate`.

  After this method has finished execution, both `needsDisplay` and `needsRepositioning` are set
  back to false.
  */
  internal final func sendChangeEvent() {
    // TODO:(vicng) Change these events so it's easy to create new ones based on flags
    if self.needsDisplay {
      self.delegate?.layoutDisplayChanged(self)
    } else if self.needsRepositioning {
      self.delegate?.layoutPositionChanged(self)
    }

    self.needsDisplay = false
    self.needsRepositioning = false
  }

  // MARK: - Private

  /**
  Updates the `totalSize` value based on the current state of `contentSize` and `edgeInsets`.
  */
  private func updateTotalSize() {
    totalSize.width = contentSize.width + edgeInsets.left + edgeInsets.right
    totalSize.height = contentSize.height + edgeInsets.top + edgeInsets.bottom
  }
}
