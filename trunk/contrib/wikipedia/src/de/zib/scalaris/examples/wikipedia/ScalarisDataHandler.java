/**
 *  Copyright 2011 Zuse Institute Berlin
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */
package de.zib.scalaris.examples.wikipedia;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;

import de.zib.scalaris.Connection;
import de.zib.scalaris.ConnectionException;
import de.zib.scalaris.ErlangValue;
import de.zib.scalaris.NotFoundException;
import de.zib.scalaris.Transaction;
import de.zib.scalaris.TransactionSingleOp;
import de.zib.scalaris.examples.wikipedia.bliki.MyNamespace;
import de.zib.scalaris.examples.wikipedia.bliki.MyWikiModel;
import de.zib.scalaris.examples.wikipedia.data.Page;
import de.zib.scalaris.examples.wikipedia.data.Revision;
import de.zib.scalaris.examples.wikipedia.data.ShortRevision;
import de.zib.scalaris.examples.wikipedia.data.SiteInfo;

/**
 * Retrieves and writes values from/to Scalaris.
 * 
 * @author Nico Kruber, kruber@zib.de
 */
public class ScalarisDataHandler {
    /**
     * Gets the key to store {@link SiteInfo} objects at.
     * 
     * @return Scalaris key
     */
    public final static String getSiteInfoKey() {
        return "siteinfo";
    }
    
    /**
     * Gets the key to store the (complete) list of pages at.
     * 
     * @return Scalaris key
     */
    public final static String getPageListKey() {
        return "pages";
    }
    
    /**
     * Gets the key to store the number of pages at.
     * 
     * @return Scalaris key
     */
    public final static String getPageCountKey() {
        return "pages:count";
    }
    
    /**
     * Gets the key to store the (complete) list of articles, i.e. pages in
     * the main namespace) at.
     * 
     * @return Scalaris key
     */
    public final static String getArticleListKey() {
        return "articles";
    }
    
    /**
     * Gets the key to store the number of articles, i.e. pages in the main
     * namespace, at.
     * 
     * @return Scalaris key
     */
    public final static String getArticleCountKey() {
        return "articles:count";
    }
    
    /**
     * Gets the key to store {@link Revision} objects at.
     * 
     * @param title     the title of the page
     * @param id        the id of the revision
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getRevKey(String title, int id, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":rev:" + id;
    }
    
    /**
     * Gets the key to store {@link Page} objects at.
     * 
     * @param title     the title of the page
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getPageKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":page";
    }
    
    /**
     * Gets the key to store the list of revisions of a page at.
     * 
     * @param title     the title of the page
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getRevListKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":revs";
    }
    
    /**
     * Gets the key to store the list of pages belonging to a category at.
     * 
     * @param title     the category title (including <tt>Category:</tt>)
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getCatPageListKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":cpages";
    }
    
    /**
     * Gets the key to store the number of pages belonging to a category at.
     * 
     * @param title     the category title (including <tt>Category:</tt>)
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getCatPageCountKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":cpages:count";
    }
    
    /**
     * Gets the key to store the list of pages using a template at.
     * 
     * @param title     the template title (including <tt>Template:</tt>)
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getTplPageListKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":tpages";
    }
    
    /**
     * Gets the key to store the list of pages linking to the given title.
     * 
     * @param title     the page's title
     * @param nsObject  the namespace for page title normalisation
     * 
     * @return Scalaris key
     */
    public final static String getBackLinksPageListKey(String title, final MyNamespace nsObject) {
        return MyWikiModel.normalisePageTitle(title, nsObject) + ":blpages";
    }
    
    /**
     * Gets the key to store the number of page edits.
     * 
     * @return Scalaris key
     */
    public final static String getStatsPageEditsKey() {
        return "stats:pageedits";
    }
    
    /**
     * Retrieves a page's history from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the page
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page history on success
     */
    public static PageHistoryResult getPageHistory(Connection connection, String title, final MyNamespace nsObject) {
        if (connection == null) {
            return new PageHistoryResult(false, "no connection to Scalaris", true);
        }
        
        TransactionSingleOp scalaris_single;

        scalaris_single = new TransactionSingleOp(connection);
        TransactionSingleOp.RequestList requests = new TransactionSingleOp.RequestList();
        requests.addRead(getPageKey(title, nsObject)).addRead(getRevListKey(title, nsObject));
        
        TransactionSingleOp.ResultList results;
        try {
            results = scalaris_single.req_list(requests);
        } catch (Exception e) {
            return new PageHistoryResult(false, "unknown exception reading \"" + getPageKey(title, nsObject) + "\" or \"" + getRevListKey(title, nsObject) + "\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        
        Page page;
        try {
            page = results.processReadAt(0).jsonValue(Page.class);
        } catch (NotFoundException e) {
            PageHistoryResult result = new PageHistoryResult(false, "page not found at \"" + getPageKey(title, nsObject) + "\"", false);
            result.not_existing = true;
            return result;
        } catch (Exception e) {
            return new PageHistoryResult(false, "unknown exception reading \"" + getPageKey(title, nsObject) + "\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }

        List<ShortRevision> revisions;
        try {
            revisions = results.processReadAt(1).jsonListValue(ShortRevision.class);
        } catch (NotFoundException e) {
            PageHistoryResult result = new PageHistoryResult(false, "revision list \"" + getRevListKey(title, nsObject) + "\" does not exist", false);
            result.not_existing = true;
            return result;
        } catch (Exception e) {
            return new PageHistoryResult(false, "unknown exception reading \"" + getRevListKey(title, nsObject) + "\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        return new PageHistoryResult(page, revisions);
    }

    /**
     * Retrieves the current, i.e. most up-to-date, version of a page from
     * Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the page
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page and revision on success
     */
    public static RevisionResult getRevision(Connection connection, String title, final MyNamespace nsObject) {
        return getRevision(connection, title, -1, nsObject);
    }

    /**
     * Retrieves the given version of a page from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the page
     * @param id
     *            the id of the version
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page and revision on success
     */
    public static RevisionResult getRevision(Connection connection, String title, int id, final MyNamespace nsObject) {
        if (connection == null) {
            return new RevisionResult(false, "no connection to Scalaris", true);
        }
        
        TransactionSingleOp scalaris_single;
        String scalaris_key;
        
        scalaris_single = new TransactionSingleOp(connection);
        
        RevisionResult result = new RevisionResult();

        Page page;
        scalaris_key = getPageKey(title, nsObject);
        try {
            page = scalaris_single.read(scalaris_key).jsonValue(Page.class);
        } catch (NotFoundException e) {
            result.success = false;
            result.message = "page not found at \"" + scalaris_key + "\"";
            result.page_not_existing = true;
            return result;
        } catch (Exception e) {
            e.printStackTrace();
            result.success = false;
            result.message = "unknown exception reading \"" + scalaris_key + "\" from Scalaris: " + e.getMessage();
            result.page_not_existing = true;
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        result.page = page;

        // load requested version if it is not the current one cached in the Page object
        if (id != page.getCurRev().getId() && id >= 0) {
            scalaris_key = getRevKey(title, id, nsObject);
            try {
                Revision revision = scalaris_single.read(scalaris_key).jsonValue(Revision.class);
                result.revision = revision;
            } catch (NotFoundException e) {
                result.success = false;
                result.message = "revision not found at \"" + scalaris_key + "\"";
                result.rev_not_existing = true;
                return result;
            } catch (Exception e) {
                //      e.printStackTrace();
                result.success = false;
                result.message = "unknown exception reading \"" + scalaris_key + "\" from Scalaris: " + e.getMessage();
                result.rev_not_existing = true;
                result.connect_failed = e instanceof ConnectionException;
                return result;
            }
        } else {
            result.revision = page.getCurRev();
        }
        
        return result;
    }

    /**
     * Retrieves a list of available pages from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * 
     * @return a result object with the page list on success
     */
    public static PageListResult getPageList(Connection connection) {
        return getPageList2(connection, getPageListKey(), false);
    }

    /**
     * Retrieves a list of available articles, i.e. pages in the main
     * namespace, from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * 
     * @return a result object with the page list on success
     */
    public static PageListResult getArticleList(Connection connection) {
        return getPageList2(connection, getArticleListKey(), false);
    }

    /**
     * Retrieves a list of pages in the given category from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the category
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page list on success
     */
    public static PageListResult getPagesInCategory(Connection connection, String title, final MyNamespace nsObject) {
        return getPageList2(connection, getCatPageListKey(title, nsObject), false);
    }

    /**
     * Retrieves a list of pages using the given template from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the template
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page list on success
     */
    public static PageListResult getPagesInTemplate(Connection connection, String title, final MyNamespace nsObject) {
        return getPageList2(connection, getTplPageListKey(title, nsObject), true);
    }

    /**
     * Retrieves a list of pages linking to the given page from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the page
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the page list on success
     */
    public static PageListResult getPagesLinkingTo(Connection connection, String title, final MyNamespace nsObject) {
        return getPageList2(connection, getBackLinksPageListKey(title, nsObject), false);
    }

    /**
     * Retrieves a list of pages from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param scalaris_key
     *            the key under which the page list is stored in Scalaris
     * @param failNotFound
     *            whether the operation should fail if the key is not found or
     *            not
     * 
     * @return a result object with the page list on success
     */
    private static PageListResult getPageList2(Connection connection,
            String scalaris_key, boolean failNotFound) {
        if (connection == null) {
            return new PageListResult(false, "no connection to Scalaris", true);
        }
        
        TransactionSingleOp scalaris_single = new TransactionSingleOp(connection);
        try {
            List<String> pages = scalaris_single.read(scalaris_key).stringListValue();
            return new PageListResult(pages);
        } catch (NotFoundException e) {
            if (failNotFound) {
                return new PageListResult(false, "unknown exception reading page list at \"" + scalaris_key + "\" from Scalaris: " + e.getMessage(), false);
            } else {
                return new PageListResult(new LinkedList<String>());
            }
        } catch (Exception e) {
            return new PageListResult(false, "unknown exception reading page list at \"" + scalaris_key + "\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
    }

    /**
     * Retrieves the number of available pages from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * 
     * @return a result object with the number of pages on success
     */
    public static BigIntegerResult getPageCount(Connection connection) {
        return getInteger2(connection, getPageCountKey(), false);
    }

    /**
     * Retrieves the number of available articles, i.e. pages in the main
     * namespace, from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * 
     * @return a result object with the number of articles on success
     */
    public static BigIntegerResult getArticleCount(Connection connection) {
        return getInteger2(connection, getArticleCountKey(), false);
    }

    /**
     * Retrieves the number of pages in the given category from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param title
     *            the title of the category
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return a result object with the number of pages on success
     */
    public static BigIntegerResult getPagesInCategoryCount(Connection connection, String title, final MyNamespace nsObject) {
        return getInteger2(connection, getCatPageCountKey(title, nsObject), false);
    }

    /**
     * Retrieves the number of available articles, i.e. pages in the main
     * namespace, from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * 
     * @return a result object with the number of articles on success
     */
    public static BigIntegerResult getStatsPageEdits(Connection connection) {
        return getInteger2(connection, getStatsPageEditsKey(), false);
    }

    /**
     * Retrieves an integral number from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param scalaris_key
     *            the key under which the number is stored in Scalaris
     * @param failNotFound
     *            whether the operation should fail if the key is not found or
     *            not
     * 
     * @return a result object with the number on success
     */
    private static BigIntegerResult getInteger2(Connection connection,
            String scalaris_key, boolean failNotFound) {
        if (connection == null) {
            return new BigIntegerResult(false, "no connection to Scalaris", true);
        }
        
        TransactionSingleOp scalaris_single = new TransactionSingleOp(connection);
        try {
            BigInteger number = scalaris_single.read(scalaris_key).bigIntValue();
            return new BigIntegerResult(number);
        } catch (NotFoundException e) {
            if (failNotFound) {
                return new BigIntegerResult(false, "unknown exception reading (integral) number at \"" + scalaris_key + "\" from Scalaris: " + e.getMessage(), false);
            } else {
                return new BigIntegerResult(BigInteger.valueOf(0));
            }
        } catch (Exception e) {
            return new BigIntegerResult(false, "unknown exception reading (integral) number at \"" + scalaris_key + "\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
    }

    /**
     * Retrieves a random page title from Scalaris.
     * 
     * @param connection
     *            the connection to Scalaris
     * @param random
     *            the random number generator to use
     * 
     * @return a result object with the page list on success
     */
    public static RandomTitleResult getRandomArticle(Connection connection, Random random) {
        if (connection == null) {
            return new RandomTitleResult(false, "no connection to Scalaris", true);
        }
        
        TransactionSingleOp scalaris_single = new TransactionSingleOp(connection);
        try {
            List<ErlangValue> pages = scalaris_single.read(getArticleListKey()).listValue();
            String randomTitle = pages.get(random.nextInt(pages.size())).stringValue();
            return new RandomTitleResult(randomTitle);
        } catch (Exception e) {
            return new RandomTitleResult(false, "unknown exception reading page list at \"pages\" from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
    }

    /**
     * Saves or edits a page with the given parameters
     * 
     * @param connection
     *            the connection to use
     * @param title
     *            the title of the page
     * @param newRev
     *            the new revision to add
     * @param prevRevId
     *            the version of the previously existing revision or <tt>-1</tt>
     *            if there was no previous revision
     * @param restrictions
     *            new restrictions of the page or <tt>null</tt> if they should
     *            not be changed
     * @param siteinfo
     *            information about the wikipedia (used for parsing categories
     *            and templates)
     * @param username
     *            name of the user editing the page (for enforcing restrictions)
     * @param nsObject
     *            the namespace for page title normalisation
     * 
     * @return success status
     */
    public static SavePageResult savePage(Connection connection, String title,
            Revision newRev, int prevRevId, Map<String, String> restrictions,
            SiteInfo siteinfo, String username, final MyNamespace nsObject) {
        if (connection == null) {
            return new SavePageResult(false, "no connection to Scalaris", true);
        }
        
        Transaction scalaris_tx = new Transaction(connection);
        SavePageResult result = new SavePageResult();

        // check that the current version is still up-to-date:
        // read old version first, then write
        int oldRevId = -1;
        String pageInfoKey = getPageKey(title, nsObject);
        String revListKey = getRevListKey(title, nsObject);
        
        Transaction.RequestList requests = new Transaction.RequestList();
        requests.addRead(pageInfoKey).addRead(revListKey);
        
        Transaction.ResultList results;
        try {
            results = scalaris_tx.req_list(requests);
        } catch (Exception e) {
//          e.printStackTrace();
            return new SavePageResult(false, "unknown exception getting page info (" + pageInfoKey + ") or revision info (" + revListKey + ") from Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        
        try {
            result.oldPage = results.processReadAt(0).jsonValue(Page.class);
            result.newPage = new Page(result.oldPage.getTitle(),
                    result.oldPage.getId(), result.oldPage.isRedirect(),
                    new LinkedHashMap<String, String>(
                            result.oldPage.getRestrictions()), newRev);
            oldRevId = result.oldPage.getCurRev().getId();
        } catch (NotFoundException e) {
            // this is ok and means that the page did not exist yet
            result.newPage = new Page();
            result.newPage.setTitle(title);
            result.newPage.setCurRev(newRev);
        } catch (Exception e) {
//          e.printStackTrace();
            result.success = false;
            result.message = "unknown exception reading \"" + pageInfoKey + "\" from Scalaris: " + e.getMessage();
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        
        if (!result.newPage.checkEditAllowed(username)) {
            result.success = false;
            result.message = "operation not allowed: edit is restricted";
            return result;
        }
        
        if (prevRevId != oldRevId) {
            result.success = false;
            result.message = "curRev(" + oldRevId + ") != oldRev(" + prevRevId + ")";
            return result;
        }

        try {
            result.newShortRevs = results.processReadAt(1).jsonListValue(ShortRevision.class);
        } catch (NotFoundException e) {
            if (prevRevId == -1) { // new page?
                result.newShortRevs = new LinkedList<ShortRevision>();
            } else {
//              e.printStackTrace();
                // corrupt DB - don't save page
                result.success = false;
                result.message = "revision list for page \"" + title + "\" not found at \"" + revListKey + "\"";
                return result;
            }
        } catch (Exception e) {
//          e.printStackTrace();
            result.success = false;
            result.message = "unknown exception reading \"" + revListKey + "\" from Scalaris: " + e.getMessage();
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        result.newShortRevs.add(0, new ShortRevision(newRev));

        // write:
        // get previous categories and templates:
        final MyWikiModel wikiModel = new MyWikiModel("", "", new MyNamespace(siteinfo));
        wikiModel.setPageName(title);
        Set<String> oldCats;
        Set<String> oldTpls;
        Set<String> oldLnks;
        if (oldRevId != -1 && result.oldPage != null && result.oldPage.getCurRev() != null) {
            // get a list of previous categories and templates:
            wikiModel.setUp();
            wikiModel.render(null, result.oldPage.getCurRev().unpackedText());
            final Set<String> oldCats0 = wikiModel.getCategories().keySet();
            final Set<String> oldTpls0 = wikiModel.getTemplates();
            final Set<String> oldLnks0 = wikiModel.getLinks();
            oldCats = new HashSet<String>(oldCats0.size());
            oldTpls = new HashSet<String>(oldTpls0.size());
            oldLnks = new HashSet<String>(oldLnks0.size());
            MyWikiModel.normalisePageTitles(oldCats0, nsObject, oldCats);
            MyWikiModel.normalisePageTitles(oldTpls0, nsObject, oldTpls);
            MyWikiModel.normalisePageTitles(oldLnks0, nsObject, oldLnks);
            wikiModel.tearDown();
        } else {
            oldCats = new HashSet<String>();
            oldTpls = new HashSet<String>();
            oldLnks = new HashSet<String>();
        }
        // get new categories and templates
        wikiModel.setUp();
        wikiModel.render(null, newRev.unpackedText());
        // note: do not tear down the wiki model - the following statements
        // still need it and it will be removed at the end of the method anyway
        final Set<String> newCats0 = wikiModel.getCategories().keySet();
        final Set<String> newTpls0 = wikiModel.getTemplates();
        final Set<String> newLnks0 = wikiModel.getLinks();
        Set<String> newCats = new HashSet<String>(newCats0.size());
        Set<String> newTpls = new HashSet<String>(newTpls0.size());
        Set<String> newLnks = new HashSet<String>(newLnks0.size());
        MyWikiModel.normalisePageTitles(newCats0, nsObject, newCats);
        MyWikiModel.normalisePageTitles(newTpls0, nsObject, newTpls);
        MyWikiModel.normalisePageTitles(newLnks0, nsObject, newLnks);
        Difference catDiff = new Difference(oldCats, newCats);
        Difference tplDiff = new Difference(oldTpls, newTpls);
        Difference lnkDiff = new Difference(oldLnks, newLnks);

        // write differences (categories, templates, backlinks)
        Difference.GetPageListKey catPageKeygen = new Difference.GetPageListAndCountKey() {
            @Override
            public String getPageListKey(String name) {
                return getCatPageListKey(wikiModel.getCategoryNamespace() + ":" + name, nsObject);
            }

            @Override
            public String getPageCountKey(String name) {
                return getCatPageCountKey(wikiModel.getCategoryNamespace() + ":" + name, nsObject);
            }
        };
        Difference.GetPageListKey tplPageKeygen = new Difference.GetPageListKey() {
            @Override
            public String getPageListKey(String name) {
                return getTplPageListKey(wikiModel.getTemplateNamespace() + ":" + name, nsObject);
            }
        };
        Difference.GetPageListKey lnkPageKeygen = new Difference.GetPageListKey() {
            @Override
            public String getPageListKey(String name) {
                return getBackLinksPageListKey(name, nsObject);
            }
        };
        requests = new Transaction.RequestList();
        int catPageReads = catDiff.updatePageLists_prepare_read(requests, catPageKeygen, title);
        int tplPageReads = tplDiff.updatePageLists_prepare_read(requests, tplPageKeygen, title);
        lnkDiff.updatePageLists_prepare_read(requests, lnkPageKeygen, title);
        results = null;
        try {
            results = scalaris_tx.req_list(requests);
        } catch (Exception e) {
            //          e.printStackTrace();
            result.success = false;
            result.message = "unknown exception reading page lists for page \"" + title + "\" from Scalaris: " + e.getMessage();
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        requests = new Transaction.RequestList();
        SaveResult pageListResult;
        pageListResult = catDiff.updatePageLists_prepare_write(results, requests, catPageKeygen, title, 0);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }
        pageListResult = tplDiff.updatePageLists_prepare_write(results, requests, tplPageKeygen, title, catPageReads);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }
        pageListResult = lnkDiff.updatePageLists_prepare_write(results, requests, lnkPageKeygen, title, catPageReads + tplPageReads);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }
        results = null;
        try {
            results = scalaris_tx.req_list(requests);
        } catch (Exception e) {
            //          e.printStackTrace();
            result.success = false;
            result.message = "unknown exception writing page lists for page \"" + title + "\" to Scalaris: " + e.getMessage();
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        pageListResult = catDiff.updatePageLists_check_writes(results, catPageKeygen, title, 0);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }
        pageListResult = tplDiff.updatePageLists_check_writes(results, tplPageKeygen, title, catPageReads);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }
        pageListResult = lnkDiff.updatePageLists_check_writes(results, lnkPageKeygen, title, catPageReads + tplPageReads);
        if (!pageListResult.success) {
            result.success = false;
            result.message = pageListResult.message;
            result.connect_failed = pageListResult.connect_failed;
            return result;
        }

        if (wikiModel.getRedirectLink() != null) {
            result.newPage.setRedirect(true);
        }
        
        if (restrictions != null) {
            result.newPage.setRestrictions(restrictions);
        }
        
        requests = new Transaction.RequestList();
        // new page? -> add to page/article lists
        List<Integer> pageListWrites = new ArrayList<Integer>(2);
        List<String> pageListKeys = new LinkedList<String>();
        if (oldRevId == -1) {
            pageListKeys.add(getPageListKey());
            pageListKeys.add(getPageCountKey());
            if (wikiModel.getNamespace(title).isEmpty()) {
                pageListKeys.add(getArticleListKey());
                pageListKeys.add(getArticleCountKey());
            }
            
            for (Iterator<String> it = pageListKeys.iterator(); it.hasNext();) {
                String pageList_key = (String) it.next();
                @SuppressWarnings("unused")
                String pageCount_key = (String) it.next();
                
                updatePageList_prepare_read(requests, pageList_key);
            }
            try {
                results = scalaris_tx.req_list(requests);
            } catch (Exception e) {
//                e.printStackTrace();
                result.success = false;
                result.message = "unknown exception reading page lists for page \"" + title + "\" to Scalaris: " + e.getMessage();
                result.connect_failed = e instanceof ConnectionException;
                return result;
            }

            requests = new Transaction.RequestList();
            final List<String> newPages = Arrays.asList(wikiModel.normalisePageTitle(title));
            for (Iterator<String> it = pageListKeys.iterator(); it.hasNext();) {
                String pageList_key = (String) it.next();
                String pageCount_key = (String) it.next();
                
                pageListResult = updatePageList_prepare_write(results, requests, pageList_key, pageCount_key, new LinkedList<String>(), newPages, 0);
                if (!result.success) {
                    result.success = false;
                    result.message = pageListResult.message;
                    result.connect_failed = pageListResult.connect_failed;
                    return result;
                }
                pageListWrites.add((Integer) pageListResult.info);
            }
        }
        
        requests.addWrite(getPageKey(title, nsObject), result.newPage)
                .addWrite(getRevKey(title, newRev.getId(), nsObject), newRev)
                .addWrite(getRevListKey(title, nsObject), result.newShortRevs).addCommit();
        try {
            results = scalaris_tx.req_list(requests);

            int curOp = 0;
            int pageList = 0;
            for (Iterator<String> it = pageListKeys.iterator(); it.hasNext();) {
                String pageList_key = (String) it.next();
                String pageCount_key = (String) it.next();
                
                pageListResult = updatePageList_check_writes(results, pageList_key, pageCount_key, 0, pageListWrites.get(pageList));
                if (!pageListResult.success) {
                    result.success = false;
                    result.message = pageListResult.message;
                    result.connect_failed = pageListResult.connect_failed;
                    return result;
                }
                ++curOp;
                ++pageList;
            }
            
            results.processWriteAt(curOp++);
            results.processWriteAt(curOp++);
            results.processWriteAt(curOp++);
        } catch (Exception e) {
//          e.printStackTrace();
            result.success = false;
            result.message = "unknown exception writing page \"" + title + "\" to Scalaris: " + e.getMessage();
            result.connect_failed = e instanceof ConnectionException;
            return result;
        }
        
        // increase number of page edits (for statistics)
        // as this is not that important, use a seperate transaction and do not fail if updating the value fails
        try {
            String scalaris_key = getStatsPageEditsKey();
            try {
                result.pageEdits = scalaris_tx.read(scalaris_key).bigIntValue();
            } catch (NotFoundException e) {
                result.pageEdits = BigInteger.valueOf(0);
            }
            result.pageEdits = result.pageEdits.add(BigInteger.valueOf(1));
            requests = new Transaction.RequestList();
            requests.addWrite(scalaris_key, result.pageEdits).addCommit();
            scalaris_tx.req_list(requests);
        } catch (Exception e) {
        }
        
        return result;
    }
    
    /**
     * Handles differences of sets.
     * 
     * @author Nico Kruber, kruber@zib.de
     */
    private static class Difference {
        public Set<String> onlyOld;
        public Set<String> onlyNew;
        @SuppressWarnings("unchecked")
        private Set<String>[] changes = new Set[2];
        
        public Difference(Set<String> oldSet, Set<String> newSet) {
            this.onlyOld = new HashSet<String>(oldSet);
            this.onlyNew = new HashSet<String>(newSet);
            onlyOld.removeAll(newSet);
            onlyNew.removeAll(oldSet);
            changes[0] = onlyOld;
            changes[1] = onlyNew;
        }
        
        static public interface GetPageListKey {
            /**
             * Gets the Scalaris key for a page list for the given article's
             * name.
             * 
             * @param name the name of an article
             * @return the key for Scalaris
             */
            public abstract String getPageListKey(String name);
        }
        
        static public interface GetPageListAndCountKey extends GetPageListKey {
            /**
             * Gets the Scalaris key for a page list counter for the given
             * article's name.
             * 
             * @param name the name of an article
             * @return the key for Scalaris
             */
            public abstract String getPageCountKey(String name);
        }
        
        /**
         * Adds read operations to the given request list as required by
         * {@link #updatePageLists_prepare_write(de.zib.scalaris.Transaction.ResultList, de.zib.scalaris.Transaction.RequestList, GetPageListKey, String, int)}.
         * 
         * @param readRequests
         *            list of requests, i.e. operations for Scalaris
         * @param keyGen
         *            object creating the Scalaris key for the page lists (based
         *            on a set entry)
         * @param title
         *            page name to update
         * 
         * @return the number of added requests, i.e. operations
         */
        public int updatePageLists_prepare_read(Transaction.RequestList readRequests, GetPageListKey keyGen, String title) {
            int ops = 0;
            // read old and new page lists
            for (Set<String> curList : changes) {
                for (String name: curList) {
                    readRequests.addRead(keyGen.getPageListKey(name));
                    if (keyGen instanceof GetPageListAndCountKey) {
                        GetPageListAndCountKey keyCountGen = (GetPageListAndCountKey) keyGen;
                        readRequests.addRead(keyCountGen.getPageCountKey(name));
                    }
                    ++ops;
                }
            }
            return ops;
        }
        
        /**
         * Removes <tt>title</tt> from the list of pages in the old set and adds
         * it to the new ones. Evaluates reads from
         * {@link #updatePageLists_prepare_read(de.zib.scalaris.Transaction.RequestList, GetPageListKey, String)}
         * and adds writes to the given request list.
         * 
         * @param readResults
         *            results of previous read operations by
         *            {@link #updatePageLists_prepare_read(de.zib.scalaris.Transaction.RequestList, GetPageListKey, String)}
         * @param writeRequests
         *            list of requests, i.e. operations for Scalaris
         * @param keyGen
         *            object creating the Scalaris key for the page lists (based
         *            on a set entry)
         * @param title
         *            page name to update
         * @param firstOp
         *            position of the first operation in the result list
         * 
         * @return the result of the operation
         */
        public SaveResult updatePageLists_prepare_write(Transaction.ResultList readResults, Transaction.RequestList writeRequests, GetPageListKey keyGen, String title, int firstOp) {
            String scalaris_key;
            // beware: keep order of operations in sync with readPageLists_prepare!
            // remove from old page list
            for (String name: onlyOld) {
                scalaris_key = keyGen.getPageListKey(name);
//                System.out.println("-" + scalaris_key);
                try {
                    List<String> pageList = readResults.processReadAt(firstOp++).stringListValue();
                    pageList.remove(title);
                    writeRequests.addWrite(scalaris_key, pageList);
                } catch (NotFoundException e) {
                    // this is ok
                } catch (Exception e) {
                    return new SaveResult(false, "unknown exception updating \"" + scalaris_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
                }
            }
            // add to new page list
            for (String name: onlyNew) {
                scalaris_key = keyGen.getPageListKey(name);
//                System.out.println("+" + scalaris_key);
                List<String> pageList;
                try {
                    pageList = readResults.processReadAt(firstOp++).stringListValue();
                } catch (NotFoundException e) {
                    // this is ok
                    pageList = new LinkedList<String>();
                } catch (Exception e) {
                    return new SaveResult(false, "unknown exception updating \"" + scalaris_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
                }
                pageList.add(title);
                try {
                    writeRequests.addWrite(scalaris_key, pageList);
                } catch (Exception e) {
                    return new SaveResult(false, "unknown exception updating \"" + scalaris_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
                }
                if (keyGen instanceof GetPageListAndCountKey) {
                    GetPageListAndCountKey keyCountGen = (GetPageListAndCountKey) keyGen;
                    writeRequests.addWrite(keyCountGen.getPageCountKey(name), pageList.size());
                }
            }
            return new SaveResult();
        }
        
        /**
         * Checks whether all writes from
         * {@link #updatePageLists_prepare_write(de.zib.scalaris.Transaction.ResultList, de.zib.scalaris.Transaction.RequestList, GetPageListKey, String, int)}
         * were successful.
         * 
         * @param writeResults
         *            results of previous write operations by
         *            {@link #updatePageLists_prepare_write(de.zib.scalaris.Transaction.ResultList, de.zib.scalaris.Transaction.RequestList, GetPageListKey, String, int)}
         * @param keyGen
         *            object creating the Scalaris key for the page lists (based
         *            on a set entry)
         * @param title
         *            page name to update
         * @param firstOp
         *            position of the first operation in the result list
         * 
         * @return the result of the operation
         */
        public SaveResult updatePageLists_check_writes(Transaction.ResultList writeResults, GetPageListKey keyGen, String title, int firstOp) {
            // beware: keep order of operations in sync with readPageLists_prepare!
            // evaluate results changing the old and new page lists
            for (Set<String> curList : changes) {
                for (String name: curList) {
                    try {
                        writeResults.processWriteAt(firstOp++);
                    } catch (Exception e) {
                        return new SaveResult(false, "unknown exception updating \"" + keyGen.getPageListKey(name) + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
                    }
                }
            }
            return new SaveResult();
        }
    }
    
    /**
     * Updates a list of pages by removing and/or adding new page titles.
     * 
     * @param requests
     *            list of requests, i.e. operations for Scalaris
     * @param pageList_key
     *            Scalaris key for the page list
     * 
     * @return the number of added requests, i.e. operations
     */
    protected static int updatePageList_prepare_read(Transaction.RequestList requests, String pageList_key) {
        requests.addRead(pageList_key);
        return 1;
    }
    
    /**
     * Updates a list of pages by removing and/or adding new page titles.
     * 
     * @param readResults
     *            results of previous read operations by
     *            {@link #updatePageList_prepare_read(RequestList, String)}
     * @param writeRequests
     *            list of requests, i.e. operations for Scalaris
     * @param pageList_key
     *            Scalaris key for the page list
     * @param pageCount_key
     *            Scalaris key for the number of pages in the list (may be null
     *            if not used)
     * @param entriesToRemove
     *            (normalised) page names to remove
     * @param entriesToAdd
     *            (normalised) page names to add
     * @param firstOp
     *            number of the first operation in the result set
     * 
     * @return the result of the operation
     */
    protected static SaveResult updatePageList_prepare_write(Transaction.ResultList readResults, Transaction.RequestList writeRequests, String pageList_key, String pageCount_key, Collection<String> entriesToRemove, Collection<String> entriesToAdd, int firstOp) {
        List<String> pages;
        try {
            pages = readResults.processReadAt(firstOp++).stringListValue();
        } catch (NotFoundException e) {
            pages = new LinkedList<String>();
        } catch (Exception e) {
            return new SaveResult(false, "unknown exception updating \"" + pageList_key + "\" and \"" + pageCount_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        // note: no need to read the old count - we already have a list of all pages and can calculate the count on our own
        int oldCount = pages.size();
        
        int count = oldCount;
        boolean listChanged = false;
        
        pages.removeAll(entriesToRemove);
        if (pages.size() != count) {
            listChanged = true;
        }
        count = pages.size();
        
        pages.addAll(entriesToAdd);
        if (pages.size() != count) {
            listChanged = true;
        }
        count = pages.size();

        int writeOps = 0;
        if (listChanged) {
            writeRequests.addWrite(pageList_key, pages);
            ++writeOps;
            if (pageCount_key != null && !pageCount_key.isEmpty() && count != oldCount) {
                writeRequests.addWrite(pageCount_key, count);
                ++writeOps;
            }
        }
        SaveResult res = new SaveResult();
        res.info = writeOps;
        return res;
    }
    
    /**
     * Updates a list of pages by removing and/or adding new page titles.
     * 
     * @param writeResults
     *            results of previous write operations by
     *            {@link #updatePageList_prepare_write(ResultList, RequestList, String, String, Collection, Collection, int)}
     * @param pageList_key
     *            Scalaris key for the page list
     * @param pageCount_key
     *            Scalaris key for the number of pages in the list (may be null
     *            if not used)
     * @param firstOp
     *            position of the first operation in the result list
     * @param writeOps
     *            number of supposed write operations
     * 
     * @return the result of the operation
     */
    protected static SaveResult updatePageList_check_writes(Transaction.ResultList writeResults, String pageList_key, String pageCount_key, int firstOp, int writeOps) {
        try {
            for (int i = 0; i < writeOps; ++i) {
                writeResults.processWriteAt(firstOp + i);
            }
        } catch (Exception e) {
            return new SaveResult(false, "unknown exception updating \"" + pageList_key + "\" and \"" + pageCount_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        return new SaveResult();
    }
    
    /**
     * Updates a list of pages by removing and/or adding new page titles.
     * 
     * @param scalaris_tx
     *            connection to Scalaris
     * @param pageList_key
     *            Scalaris key for the page list
     * @param pageCount_key
     *            Scalaris key for the number of pages in the list (may be null
     *            if not used)
     * @param entriesToRemove
     *            list of (normalised) page names to remove from the list
     * @param entriesToAdd
     *            list of (normalised) page names to add to the list
     * 
     * @return the result of the operation
     */
    public static SaveResult updatePageList(Transaction scalaris_tx, String pageList_key, String pageCount_key, Collection<String> entriesToRemove, Collection<String> entriesToAdd) {
        Transaction.RequestList requests;
        Transaction.ResultList results;

        try {
            requests = new Transaction.RequestList();
            updatePageList_prepare_read(requests, pageList_key);
            results = scalaris_tx.req_list(requests);

            requests = new Transaction.RequestList();
            SaveResult result = updatePageList_prepare_write(results, requests, pageList_key, pageCount_key, entriesToRemove, entriesToAdd, 0);
            if (!result.success) {
                return result;
            }
            requests.addCommit();
            results = scalaris_tx.req_list(requests);

            result = updatePageList_check_writes(results, pageList_key, pageCount_key, 0, (Integer) result.info);
            if (!result.success) {
                return result;
            }
        } catch (Exception e) {
            return new SaveResult(false, "unknown exception updating \"" + pageList_key + "\" and \"" + pageCount_key + "\" in Scalaris: " + e.getMessage(), e instanceof ConnectionException);
        }
        return new SaveResult();
    }
}
