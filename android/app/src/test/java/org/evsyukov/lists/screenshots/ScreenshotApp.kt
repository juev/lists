package org.evsyukov.lists.screenshots

import org.evsyukov.lists.ListsApp

/** The application of the screenshot tests: it gives the strings and opens neither the store nor the workers. */
class ScreenshotApp : ListsApp() {
    override fun onCreate() {
        instance = this
    }
}
